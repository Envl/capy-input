import AppKit
import Yams

enum AutoSwitchSetup {
    static let moduleName = "capy_auto_switch"
    static let processor = "lua_processor@*\(moduleName)"
    private static let ownershipHeader = "-- Capy Companion Auto Switch"

    static func install() throws -> Bool {
        guard let squirrel = RimeInstallation.squirrelApp,
              let resources = Bundle.main.resourceURL?.appendingPathComponent("AutoSwitch")
        else { throw AppError(L10n.autoSwitchNeedsSquirrel) }
        let modules = squirrel.appendingPathComponent("Contents/Frameworks/rime-plugins/librime-lua.dylib")
        guard FileManager.default.fileExists(atPath: modules.path) else {
            throw AppError(L10n.autoSwitchNeedsSquirrel)
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime")
        return try install(in: directory, resources: resources)
    }

    static func install(in directory: URL, resources: URL) throws -> Bool {
        let build = directory.appendingPathComponent("build")
        guard let defaults = try readConfig(build.appendingPathComponent("default.yaml")) else {
            throw AppError(L10n.autoSwitchNeedsSquirrel)
        }

        let enabled = defaults["schema_list"]?.array().compactMap { $0["schema"]?.string } ?? []
        var updates: [URL: Data?] = [:]
        var matchedAny = false
        var needsDeployment = false

        for schema in enabled {
            let config = try readConfig(build.appendingPathComponent("\(schema).schema.yaml"))
            guard let config else { continue }
            matchedAny = true

            let name = "\(schema).custom.yaml"
            let url = try RimeLibrary.checked(directory, name)
            let original = try read(url) ?? Data("patch:\n".utf8)
            guard let source = String(data: original, encoding: .utf8) else {
                throw AppError(L10n.autoSwitchPatchConflict(name))
            }
            let installed = config["engine"]?["processors"]?.array().contains { $0.string == processor } ?? false
            if !installed {
                needsDeployment = true
                if let patch = try addingProcessor(processor, to: source, name: name) {
                    updates[url] = Data(patch.utf8)
                }
            }
        }
        guard matchedAny else { throw AppError(L10n.autoSwitchNeedsSquirrel) }

        let luaPath = "lua/\(moduleName).lua"
        let luaURL = try RimeLibrary.checked(directory, luaPath)
        let bundled = try Data(contentsOf: resources.appendingPathComponent("\(moduleName).lua"))
        let originalLua = try read(luaURL)
        if originalLua != bundled {
            if let originalLua, !isAppOwnedModule(originalLua) {
                throw AppError(L10n.autoSwitchPatchConflict(luaPath))
            }
            updates[luaURL] = bundled
        }

        guard !updates.isEmpty else { return needsDeployment }
        try LibraryInstallation.replace(updates, before: [:])
        return true
    }

    private static func isAppOwnedModule(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.hasPrefix(ownershipHeader)
    }

    private static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func readConfig(_ url: URL) throws -> Node? {
        guard let data = try read(url) else { return nil }
        return try compose(yaml: String(decoding: data, as: UTF8.self))
    }

    private static func addingProcessor(_ component: String, to source: String, name: String) throws -> String? {
        let slot = "engine/processors/@before 0"
        let conflict = AppError(L10n.autoSwitchPatchConflict(name))
        let root = try compose(yaml: source)
        guard root == nil || root?.mapping != nil else { throw conflict }
        var expected = root ?? Node.mapping(.init([]))
        let patch = expected["patch"]
        let keys = patch?.mapping?.map { $0.key.string } ?? []
        let lists = ["engine/processors", "engine/processors/+"]
        if lists.contains(where: { patch?[$0]?.array().contains(where: { $0.string == component }) == true }) ||
            keys.compactMap({ $0 }).contains(where: {
                $0.hasPrefix("engine/processors/@") && patch?[$0]?.string == component
            }) { return nil }
        guard patch?[slot] == nil, patch == nil || patch?.null != nil || patch?.mapping != nil else {
            throw conflict
        }

        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        var lines = source.components(separatedBy: newline)
        // Use the parser's positions so comments and other settings stay byte-for-byte intact.
        let rootEntries = expected.mapping ?? .init([])
        let patchKey = rootEntries.first(where: { $0.key.string == "patch" })?.key
        let indentation = patch?.mapping?.first?.key.mark.map { $0.column - 1 } ?? ((patchKey?.mark?.column ?? 1) + 1)
        let lastLine = rootEntries.compactMap { $0.key.mark?.line }.max() ?? 0
        let after = patchKey?.mark?.line ?? lastLine
        let nextRoot = rootEntries.compactMap { $0.key.mark?.line }.first { $0 > after }
        let documentEnd = lines.firstIndex { $0 == "..." || $0.hasPrefix("... #") } ?? lines.count
        var index = nextRoot.map { $0 - 1 } ?? documentEnd
        while index > after && lines[index - 1].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        if patchKey == nil {
            lines.insert("patch:", at: index)
            index += 1
        }
        lines.insert(String(repeating: " ", count: indentation) + "\"\(slot)\": \(component)", at: index)
        if index == lines.count - 1 { lines.append("") }
        var newPatch = patch?.mapping.map(Node.mapping) ?? Node.mapping(.init([]))
        newPatch[slot] = Node(component)
        expected["patch"] = newPatch
        let updated = lines.joined(separator: newline)
        guard (try? compose(yaml: updated)) == expected else { throw conflict }
        return updated
    }
}
