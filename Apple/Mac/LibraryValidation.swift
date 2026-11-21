import Foundation
import Yams

struct LibraryIssue: Identifiable, Equatable, Codable {
    let path: String
    let message: String
    var id: String { path + ":" + message }
}

enum LibraryValidation {
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumLibraryBytes = 256 * 1024 * 1024

    static func mapping(_ data: Data, dictionary: Bool = false) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else { throw AppError(L10n.thisFileIsNotUTF8Text) }
        let source: String
        if dictionary {
            let lines = text.components(separatedBy: .newlines)
            guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." }) else { throw AppError(L10n.invalidDictionaryHeader) }
            source = lines[..<end].joined(separator: "\n")
        } else { source = text }
        guard let value = try Yams.load(yaml: source) as? [String: Any] else { throw AppError(L10n.expectedAYAMLSettingsMap) }
        return value
    }

    static func inspect(_ files: [String: LibraryFile]) -> [LibraryIssue] {
        var issues = [LibraryIssue](), names = Set<String>()
        func issue(_ path: String, _ message: String) { issues.append(LibraryIssue(path: path, message: message)) }
        if files.count > 10000 || files.values.reduce(0, { $0 + $1.data.count }) > maximumLibraryBytes { issue(L10n.library, L10n.theLibraryIsTooLargeToApply) }
        for (path, file) in files.sorted(by: { $0.key < $1.key }) {
            do {
                try RimeLibrary.verify([path: file])
                guard names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw AppError(L10n.anotherFileHasTheSameName) }
                guard file.data.count <= maximumFileBytes else { throw AppError(L10n.thisFileExceeds64MB) }
                if RimeLibrary.isSnapshot(path) {
                    let name = String((path as NSString).lastPathComponent.dropLast(".userdb.txt".count))
                    _ = try LearnedDictionary(data: file.data, expectedName: name)
                } else if path.hasSuffix(".yaml") || path.hasSuffix(".yml") {
                    let dictionary = path.hasSuffix(".dict.yaml")
                    let map = try mapping(file.data, dictionary: dictionary)
                    if dictionary {
                        guard let name = map["name"] as? String, !name.isEmpty else { throw AppError(L10n.theDictionaryHasNoName) }
                        for name in map["import_tables"] as? [String] ?? [] where !files.keys.contains(name + ".dict.yaml") {
                            issue(path, L10n.missingDictionary(name))
                        }
                    } else if path.hasSuffix(".schema.yaml") {
                        let expected = String((path as NSString).lastPathComponent.dropLast(".schema.yaml".count))
                        guard let schema = map["schema"] as? [String: Any], schema["schema_id"] as? String == expected,
                              let name = schema["name"] as? String, !name.isEmpty else { throw AppError(L10n.invalidSchemaID) }
                        for name in schema["dependencies"] as? [String] ?? [] where files[name + ".schema.yaml"] == nil { issue(path, L10n.missingInputMethod(name)) }
                        func dictionaries(in value: Any) {
                            if let map = value as? [String: Any] {
                                for (key, value) in map {
                                    if key == "dictionary", let name = value as? String, !name.isEmpty,
                                       files[name + ".dict.yaml"] == nil && files[name + ".table.bin"] == nil {
                                        issue(path, L10n.missingDictionary(name))
                                    } else { dictionaries(in: value) }
                                }
                            } else if let list = value as? [Any] { list.forEach { dictionaries(in: $0) } }
                        }
                        dictionaries(in: map)
                    }
                } else if path.hasSuffix(".json") {
                    _ = try JSONSerialization.jsonObject(with: file.data, options: .fragmentsAllowed)
                } else if path.hasSuffix(".lua") {
                    guard let text = String(data: file.data, encoding: .utf8) else { throw AppError(L10n.thisLuaFileIsNotUTF8Text) }
                    if let error = RimeEngine.validateLua(text, name: path, bundle: InterfaceLanguage.currentBundle) { issue(path, error) }
                }
            } catch { issue(path, error.localizedDescription) }
        }
        do {
            let ids = try enabledSchemas(files)
            if ids.isEmpty { issue("default.yaml", L10n.lastInputMethodRequired) }
            for id in ids where files[id + ".schema.yaml"] == nil { issue("default.yaml", L10n.missingEnabledInputMethod(id)) }
        } catch { issue("default.yaml", error.localizedDescription) }
        return issues
    }

    static func enabledSchemas(_ files: [String: LibraryFile]) throws -> [String] {
        let base = try files["default.yaml"].map { try mapping($0.data) } ?? [:]
        let custom = try files["default.custom.yaml"].map { try mapping($0.data) } ?? [:]
        let patch = custom["patch"] as? [String: Any] ?? [:]
        return ((patch["schema_list"] ?? base["schema_list"]) as? [[String: String]] ?? []).compactMap { $0["schema"] }
    }
}
