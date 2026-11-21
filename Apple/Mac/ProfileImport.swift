import Foundation

enum ProfileImport {
    static func compile(folder: URL, bundled: URL, profiles: URL, complete: Bool = false) throws -> String {
        let fs = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let id = UUID().uuidString
        let staging = profiles.appendingPathComponent(id)
        let scratch = fs.temporaryDirectory.appendingPathComponent(id)
        try fs.createDirectory(at: profiles, withIntermediateDirectories: true)
        if complete { try fs.createDirectory(at: staging, withIntermediateDirectories: true) }
        else { try fs.copyItem(at: bundled, to: staging) }
        defer { try? fs.removeItem(at: scratch) }
        do {
            if fs.fileExists(atPath: staging.appendingPathComponent("build").path) { try fs.removeItem(at: staging.appendingPathComponent("build")) }
            let source = folder.standardizedFileURL.resolvingSymlinksInPath()
            var schemas: [String] = []
            for (name, url) in try RimeLibrary.scan(source) {
                if !name.contains("/") && name.hasSuffix(".schema.yaml") {
                    let schema = String(name.dropLast(".schema.yaml".count))
                    if schema.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil { schemas.append(schema) }
                }
                let target = staging.appendingPathComponent(name)
                try fs.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fs.fileExists(atPath: target.path) { try fs.removeItem(at: target) }
                try fs.copyItem(at: url, to: target)
            }
            guard !schemas.isEmpty else { throw AppError(L10n.chooseSchemaFolder) }
            if !complete, !fs.fileExists(atPath: source.appendingPathComponent("default.yaml").path), !fs.fileExists(atPath: staging.appendingPathComponent("default.custom.yaml").path) {
                let patch = "patch:\n  schema_list/+:\n" + schemas.sorted().map { "    - schema: " + $0 }.joined(separator: "\n")
                try patch.write(to: staging.appendingPathComponent("default.custom.yaml"), atomically: true, encoding: .utf8)
            }
            guard let engine = RimeEngine(shared: staging.path, user: scratch.path) else { throw AppError(L10n.cannotOpenTheSchemaCompiler) }
            defer { engine.close() }
            guard engine.deploy(), !engine.schemas.isEmpty else { throw AppError(L10n.schemaCompilationFailed) }
            let compiled = scratch.appendingPathComponent("build")
            let rows = try JSONEncoder().encode(engine.firstKeyCandidateRows())
            try rows.write(to: compiled.appendingPathComponent("first-key-candidates.json"), options: .atomic)
            try fs.moveItem(at: compiled, to: staging.appendingPathComponent("build"))
            return id
        } catch {
            try? fs.removeItem(at: staging)
            throw error
        }
    }
}
