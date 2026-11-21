import AppKit
import CryptoKit
import Yams

enum ScreenWordSetup {
    private enum Schema: String, CaseIterable {
        case flypy = "double_pinyin_flypy"
        case wanxiang

        var module: String { self == .flypy ? "screen_words" : "wanxiang_screen_words" }
        var translator: String { "lua_translator@*\(module)" }

        func supports(_ config: Node) -> Bool {
            let alphabet = config["speller"]?["alphabet"]?.string ?? ""
            guard Set("abcdefghijklmnopqrstuvwxyz").isSubset(of: Set(alphabet)) else { return false }
            let marker = self == .flypy ? "xlit/QWRTYUIOPSDFGHJKLZXCVBNM/qwrtyuiopsdfghjklzxcvbnm/" : "xform/Ⅲ//"
            return config["speller"]?["algebra"]?.array().contains(where: { $0.string == marker }) == true
        }
    }

    static func install() throws -> Bool {
        guard let squirrel = RimeInstallation.squirrelApp,
              let resources = Bundle.main.resourceURL?.appendingPathComponent("ScreenWords")
        else { throw AppError(L10n.screenWordsNeedsXiaohe) }
        let modules = squirrel.appendingPathComponent("Contents/Frameworks/rime-plugins/librime-lua.dylib")
        guard FileManager.default.fileExists(atPath: modules.path) else { throw AppError(L10n.screenWordsNeedsXiaohe) }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Rime")
        return try install(in: directory, resources: resources)
    }

    static func install(in directory: URL, resources: URL) throws -> Bool {
        let build = directory.appendingPathComponent("build")
        guard let defaults = try readConfig(build.appendingPathComponent("default.yaml")) else {
            throw AppError(L10n.screenWordsNeedsXiaohe)
        }

        let enabled = defaults["schema_list"]?.array().compactMap { $0["schema"]?.string } ?? []
        var updates: [URL: Data?] = [:]
        var neededModules = Set<String>()
        var needsDeployment = false
        for schema in Schema.allCases where enabled.contains(schema.rawValue) {
            let config = try readConfig(build.appendingPathComponent("\(schema.rawValue).schema.yaml"))
            guard let config, schema.supports(config) else { continue }

            let name = "\(schema.rawValue).custom.yaml"
            let url = try RimeLibrary.checked(directory, name)
            let original = try read(url) ?? Data("patch:\n".utf8)
            guard let source = String(data: original, encoding: .utf8) else {
                throw AppError(L10n.screenWordsPatchConflict(name))
            }
            let installed = config["engine"]?["translators"]?.array().contains { $0.string == schema.translator } ?? false
            if !installed {
                needsDeployment = true
                if let patch = try addingTranslator(schema.translator, to: source, name: name) {
                    updates[url] = Data(patch.utf8)
                }
            }
            neededModules.insert("screen_words")
            neededModules.insert(schema.module)
        }
        guard !neededModules.isEmpty else { throw AppError(L10n.screenWordsNeedsXiaohe) }

        for module in neededModules {
            let path = "lua/\(module).lua"
            let url = try RimeLibrary.checked(directory, path)
            let bundled = try Data(contentsOf: resources.appendingPathComponent("\(module).lua"))
            let original = try read(url)
            if original == bundled { continue }
            // Only upgrade the exact shipped standalone scripts or app-owned versions.
            if let original, !isKnownModule(original, name: module) {
                throw AppError(L10n.screenWordsPatchConflict(path))
            }
            updates[url] = bundled
        }
        guard !updates.isEmpty else { return needsDeployment }
        try LibraryInstallation.replace(updates, before: [:])
        return true
    }

    private static func isKnownModule(_ data: Data, name: String) -> Bool {
        let legacy = [
            "screen_words": "05785ca8edbc30c14008554e2edab6dc07c920ee33f1124ede0ac21e6cf40570",
            "wanxiang_screen_words": "936daf2cda9a56f255d0f90534ce473c766395918b049eb78c61b2a4ac90f1bc"
        ]
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == legacy[name]
    }

    private static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    private static func readConfig(_ url: URL) throws -> Node? {
        guard let data = try read(url) else { return nil }
        return try compose(yaml: String(decoding: data, as: UTF8.self))
    }

    private static func addingTranslator(_ component: String, to source: String, name: String) throws -> String? {
        let slot = "engine/translators/@next"
        let conflict = AppError(L10n.screenWordsPatchConflict(name))
        let root = try compose(yaml: source)
        guard root == nil || root?.mapping != nil else { throw conflict }
        var expected = root ?? Node.mapping(.init([]))
        let patch = expected["patch"]
        let keys = patch?.mapping?.map { $0.key.string } ?? []
        let lists = ["engine/translators", "engine/translators/+"]
        if lists.contains(where: { patch?[$0]?.array().contains(where: { $0.string == component }) == true }) ||
            keys.compactMap({ $0 }).contains(where: {
                $0.hasPrefix("engine/translators/@") && patch?[$0]?.string == component
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
