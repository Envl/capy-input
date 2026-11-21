import Foundation
import AppKit

struct MaintenanceDeferred: Error {}

struct LibraryInstallation {
    let library: RimeLibrary
    let squirrel: Bool

    static func current() throws -> Self {
        let defaults = UserDefaults.standard
        let all = RimeInstallation.discover()
        guard let item = all.first(where: { $0.id == defaults.string(forKey: "rimeInstallation") }) ?? all.first else {
            throw AppError(L10n.noRimeInstallationFound)
        }
        let resources = item.canExportWithSquirrel ? RimeInstallation.squirrelApp?.appendingPathComponent("Contents/SharedSupport") :
            [URL(fileURLWithPath: "/Library/Input Methods/Fcitx5.app/Contents/share/rime-data"),
             URL(fileURLWithPath: "/opt/homebrew/share/rime-data"),
             URL(fileURLWithPath: "/usr/local/share/rime-data")].first { FileManager.default.fileExists(atPath: $0.path) }
        return Self(library: RimeLibrary(stock: resources, profile: item.dataDirectory, learned: item.syncDirectory), squirrel: item.canExportWithSquirrel)
    }

    func learnedSnapshots() throws -> [String: LibraryFile] {
        try RimeLibrary.scan(library.learned, snapshots: true).mapValues {
            LibraryFile(data: try Data(contentsOf: $0), bundled: false)
        }
    }

    func applyLearned(before: [String: LibraryFile], after: [String: LibraryFile]) throws {
        guard let root = library.learned else { throw AppError(L10n.cannotOpenTheSyncFolder) }
        try RimeLibrary.verify(after)
        let lock = open(root.path, O_RDONLY)
        guard lock >= 0 else { throw AppError(L10n.cannotOpenTheSyncFolder) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AppError(L10n.dictionarySyncIsAlreadyRunning) }
        guard try learnedSnapshots() == before else { throw LearnedSnapshotChanged() }
        var updates = [URL: Data?]()
        for (path, file) in after where file != before[path] {
            guard RimeLibrary.isSnapshot(path) else { throw AppError(L10n.invalidLearnedDictionaryPath) }
            let url = try RimeLibrary.checked(root, String(path.dropFirst("Learned/".count)))
            updates.updateValue(file.data, forKey: url)
        }
        try Self.replace(updates, before: before)
    }

    func refreshLearned(automatic: Bool = false) async throws {
        if squirrel {
            try await MainActor.run {
                if automatic && !SquirrelMaintenance.canRunAutomatically { throw MaintenanceDeferred() }
                MacDictionarySync.notifySquirrel()
            }
        }
    }

    func apply(before: [String: LibraryFile], after: [String: LibraryFile], automatic: Bool = false) async throws {
        try RimeLibrary.verify(after)
        let stock = try RimeLibrary.scan(library.stock)
        var changed = [String]()
        for path in Set(before.keys).union(after.keys) {
            if before[path]?.bundled == true && after[path]?.bundled == true { continue }
            if before[path]?.data != after[path]?.data { changed.append(path) }
        }
        guard !changed.isEmpty else { return }
        guard try library.inventory() == before else { throw AppError(L10n.rimeDataChangedRetryTheOperation) }
        let resources = changed.filter { !RimeLibrary.isSnapshot($0) && !(library.runtime != nil && RimeLibrary.isUserTable($0)) }
        var updates = [URL: Data?]()
        let excluded = Set(stock.keys).subtracting(after.keys)
        updates.updateValue(try PropertyListEncoder().encode(excluded), forKey: library.profile.appendingPathComponent(RimeLibrary.exclusionsName))
        for path in changed {
            if RimeLibrary.isSnapshot(path), let root = library.learned {
                let url = try RimeLibrary.checked(root, String(path.dropFirst("Learned/".count)))
                updates.updateValue(after[path]?.data, forKey: url)
            } else if let root = library.runtime, RimeLibrary.isUserTable(path) {
                let url = try RimeLibrary.checked(root, path)
                updates.updateValue(after[path]?.data, forKey: url)
            } else {
                let file = after[path]
                let keepStock = file?.bundled == true && stock[path] != nil
                let url = try RimeLibrary.checked(library.profile, path)
                updates.updateValue(keepStock ? nil : file?.data, forKey: url)
            }
        }
        try Self.replace(updates, before: before)
        if resources.contains(where: { !SelectedWords.recognizes($0) || !(after[$0]?.data.starts(with: before[$0]?.data ?? Data()) ?? false) }) && squirrel {
            await SquirrelMaintenance.reload(automatic: automatic)
        }
    }

    // Capture originals and validate every destination before touching a live
    // installation. Roll back only files that still match our attempted edit.
    static func replace(_ updates: [URL: Data?], before: [String: LibraryFile]) throws {
        let fs = FileManager.default
        func read(_ url: URL) throws -> Data? {
            do { return try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }
        func put(_ data: Data?, at url: URL) throws {
            if let data {
                try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } else if fs.fileExists(atPath: url.path) { try fs.removeItem(at: url) }
        }
        let originals = try Dictionary(uniqueKeysWithValues: updates.keys.map { ($0, try read($0)) })
        var written = [URL]()
        do {
            for (url, data) in updates.sorted(by: { $0.key.path < $1.key.path }) {
                let original = originals[url] ?? nil
                guard try read(url) == original else { throw AppError(L10n.fileChangedDuringSync(url.lastPathComponent)) }
                if data != original {
                    let name = url.lastPathComponent
                    if SelectedWords.recognizes(name) {
                        if let original, original != before[name]?.data { throw AppError(L10n.fileChangedDuringSync(name)) }
                        let prefix = original ?? Data()
                        if let data, data.starts(with: prefix) {
                            // The Lua writer also uses O_APPEND. A selection made between
                            // the inventory check and this write must survive the sync.
                            if original == nil { try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
                            let flags = O_WRONLY | O_APPEND | O_NOFOLLOW | (original == nil ? O_CREAT | O_EXCL : 0)
                            let fd = open(url.path, flags, S_IRUSR | S_IWUSR)
                            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                            try handle.write(contentsOf: data.dropFirst(prefix.count))
                            try handle.close()
                        } else { try put(data, at: url) }
                    } else { try put(data, at: url) }
                    written.append(url)
                }
            }
        } catch {
            for url in written.reversed() where try read(url) == (updates[url] ?? nil) {
                try put(originals[url] ?? nil, at: url)
            }
            throw error
        }
    }
}
