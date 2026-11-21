import Foundation

enum LearnedSyncService: String, CaseIterable, Identifiable {
    case icloud, server
    var id: String { rawValue }
    var title: String { self == .icloud ? "iCloud" : L10n.server }
    static let key = "learnedSyncService"

    static func isServerSyncEnabled(rawValue: Any?) -> Bool {
        if let flag = rawValue as? Bool { return flag }
        if let number = rawValue as? NSNumber { return number.boolValue }
        if let text = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !text.isEmpty, !text.hasPrefix("$(") {
            return ["1", "true", "yes", "on"].contains(text)
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static let serverSyncEnabled: Bool = isServerSyncEnabled(
        rawValue: Bundle.main.object(forInfoDictionaryKey: "CapyEnableServerSync")
    )

    static var availableCases: [Self] {
        serverSyncEnabled ? [.icloud, .server] : [.icloud]
    }

    static var selected: Self {
        guard serverSyncEnabled else { return .icloud }
        return LibraryCloud.settings.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .icloud
    }
}

struct LearnedSnapshotChanged: LocalizedError {
    var errorDescription: String? { L10n.retryAfterTyping }
}

struct ICloudDictionarySync {
    let root: URL

    static func read(_ root: URL) throws -> [String: LibraryFile] {
        var result = [String: LibraryFile](), total = 0
        for (path, url) in try RimeLibrary.scan(root, snapshots: true) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += size
            guard total <= 8 * 1024 * 1024 else { throw AppError(L10n.learnedDictionaryOverLimit) }
            let data = try Data(contentsOf: url)
            _ = try LearnedDictionary(data: data, expectedName: String(url.lastPathComponent.dropLast(".userdb.txt".count)))
            result[path] = LibraryFile(data: data, bundled: false)
        }
        return result
    }

    func run(beforeTransfer: () async throws -> Void = {}, mergeDownloads: () async throws -> Void = {}) async throws -> Int {
        try await LibraryCloud.shared.sync(.learned, root: root, read: {
            try await beforeTransfer()
            return try Self.read(root)
        }, validate: { files, _ in
            try RimeLibrary.verify(files)
            for (path, file) in files {
                guard RimeLibrary.isSnapshot(path) else { throw AppError(L10n.icloudContainsAnInvalidLearnedDictionary) }
                _ = try LearnedDictionary(data: file.data)
            }
        }, apply: { before, after in
            #if os(iOS)
            // Reconfirm the keyboard is idle before touching its live sync directory.
            try await beforeTransfer()
            #endif
            try applySnapshots(before: before, after: after)
            try await mergeDownloads()
        })
    }

    func applySnapshots(before: [String: LibraryFile], after: [String: LibraryFile]) throws {
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        var updates = [(URL, Data?)]()
        for path in changed.sorted() {
            guard RimeLibrary.isSnapshot(path) else { throw AppError(L10n.invalidLearnedDictionaryPath) }
            let url = try RimeLibrary.checked(root, String(path.dropFirst("Learned/".count)))
            let current: Data?
            do { current = try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { current = nil }
            if current == after[path]?.data { continue }
            guard current == before[path]?.data else { throw LearnedSnapshotChanged() }
            updates.append((url, after[path]?.data))
        }
        for (url, data) in updates {
            if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
