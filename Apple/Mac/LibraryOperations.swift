import Foundation

actor LibraryOperations {
    static let shared = LibraryOperations()

    func learnedWords() throws -> [String] {
        try Self.learnedWords(in: LibraryInstallation.current().learnedSnapshots())
    }

    private static func dictionaries(in files: [String: LibraryFile]) throws -> [LearnedDictionary] {
        var copies = [String: [LearnedDictionary]]()
        for (path, file) in files where RimeLibrary.isSnapshot(path) {
            let name = String((path as NSString).lastPathComponent.dropLast(".userdb.txt".count))
            copies[name, default: []].append(try LearnedDictionary(data: file.data, expectedName: name))
        }
        return try copies.values.map(LearnedDictionary.merged)
    }

    static func learnedWords(in files: [String: LibraryFile]) throws -> [String] {
        var counts = [String: Int]()
        for dictionary in try dictionaries(in: files) {
            for word in dictionary.words where !word.deleted {
                counts[word.text] = max(counts[word.text] ?? 0, word.commits)
            }
        }
        return counts.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.map(\.key)
    }

    static func deleting(_ text: String, from files: [String: LibraryFile], user: String) throws -> [String: LibraryFile] {
        var result = files
        for var dictionary in try dictionaries(in: files) {
            guard try dictionary.delete(text) else { continue }
            let path = "Learned/" + user + "/" + dictionary.name + ".userdb.txt"
            result[path] = LibraryFile(data: dictionary.encoded(user: user), bundled: false)
        }
        return result
    }

    func deleteLearnedWord(_ text: String) async throws {
        try await exportLearned()
        let install = try LibraryInstallation.current()
        let before = try install.learnedSnapshots()
        let user = UserDefaults.standard.string(forKey: "libraryWordEditorID") ?? ("editor-" + UUID().uuidString)
        UserDefaults.standard.set(user, forKey: "libraryWordEditorID")
        let after = try Self.deleting(text, from: before, user: user)
        try install.applyLearned(before: before, after: after)
        try await exportLearned()
    }

    func syncWordTables(resolutions: [LibraryResolution], automatic: Bool) async throws {
        let install = try LibraryInstallation.current()
        let folder = install.library.profile
        let root = URL.applicationSupportDirectory.appendingPathComponent("LibraryCloud")
        _ = try await LibraryCloud.shared.sync(.wordTables, root: root, resolutions: resolutions,
            read: { try RimeLibrary.selectedWordTables(at: folder) },
            validate: { files, _ in try RimeLibrary.validateWordTables(files) },
            apply: { before, after in
                guard try LibraryInstallation.current().library.profile == folder else { throw AppError(L10n.activeProfileChanged) }
                let updates = try RimeLibrary.wordTableUpdates(at: folder, before: before, after: after)
                try LibraryInstallation.replace(updates, before: before)
                let needsReload = updates.keys.contains { url in
                    let name = url.lastPathComponent
                    return !(after[name]?.data.starts(with: before[name]?.data ?? Data()) ?? false)
                }
                if install.squirrel && needsReload {
                    await SquirrelMaintenance.reload(automatic: automatic)
                }
            })
    }

    func exportLearned(automatic: Bool = false) async throws {
        let install = try LibraryInstallation.current()
        if install.squirrel, let root = install.library.learned {
            let profile = install.library.profile
            let databases = try FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { try $0.pathExtension == "userdb" && $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                .map { $0.deletingPathExtension().lastPathComponent }
            guard !databases.isEmpty else { return }
            let data = try Data(contentsOf: profile.appendingPathComponent("installation.yaml"))
            guard let owner = try LibraryValidation.mapping(data)["installation_id"] as? String else { throw AppError(L10n.exportBeforeEditing) }
            var files = [URL: String]()
            for name in databases {
                let path = owner + "/" + name + ".userdb.txt"
                guard RimeLibrary.isSnapshot("Learned/" + path) else { throw AppError(L10n.exportBeforeEditing) }
                files[try RimeLibrary.checked(root, path)] = name
            }
            if automatic, await !SquirrelMaintenance.canRunAutomatically { throw MaintenanceDeferred() }
            try await RimeSnapshotExport.wait(files: files) { MacDictionarySync.notifySquirrel() }
            return
        }
        for attempt in 0..<4 {
            do { try await LibraryInstallation.current().refreshLearned(automatic: automatic); return }
            catch is MaintenanceDeferred { throw MaintenanceDeferred() }
            catch is CancellationError { throw CancellationError() }
            catch {
                if attempt == 3 { throw error }
                try await Task.sleep(for: .milliseconds(100 * (attempt + 1)))
            }
        }
    }
    private func mergeLearned(automatic: Bool) async throws {
        if try LibraryInstallation.current().squirrel {
            await SquirrelMaintenance.merge(automatic: automatic)
            return
        }
        try await exportLearned(automatic: automatic)
    }

    func syncLearned(automatic: Bool) async throws {
        guard let root = try LibraryInstallation.current().library.learned else { return }
        if LearnedSyncService.selected == .icloud {
            _ = try await ICloudDictionarySync(root: root).run(beforeTransfer: { try await self.exportLearned(automatic: automatic) }, mergeDownloads: { try await self.mergeLearned(automatic: automatic) })
        } else if LearnedSyncService.serverSyncEnabled {
            let endpoint = DictionarySync.settings.string(forKey: "server") ?? UserDefaults.standard.string(forKey: "server") ?? DictionarySync.defaultServer
            guard let url = URL(string: endpoint), !Secret.load().isEmpty else { return }
            let client = DictionarySync(server: url, key: Secret.load(), root: root)
            _ = try await client.run(beforeTransfer: { try await self.exportLearned(automatic: automatic) }, mergeDownloads: { try await self.mergeLearned(automatic: automatic) })
        }
    }
}
