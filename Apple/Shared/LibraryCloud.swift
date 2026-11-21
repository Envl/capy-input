import Foundation
import CloudKit
import CryptoKit

/// Resources and learned snapshots use separate records. The keyboard only
/// transfers learned data; it never loads the full resource library into memory.
actor LibraryCloud {
    static let shared = LibraryCloud()
    static let containerIdentifier: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CapyICloudContainer") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return configured?.isEmpty == false ? configured! : "iCloud.com.capyinput.keyboard"
    }()
    enum Collection: String { case resources, learned }
    private var active = Set<String>()
    private final class FetchReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<CKRecord?, Error>?
        init(_ continuation: CheckedContinuation<CKRecord?, Error>) { self.continuation = continuation }
        func finish(_ result: Result<CKRecord?, Error>) {
            lock.lock()
            let current = continuation
            continuation = nil
            lock.unlock()
            current?.resume(with: result)
        }
    }

    static var settings: UserDefaults {
        #if os(iOS)
        return SharedSettings.defaults
        #else
        return .standard
        #endif
    }
    static var enabled: Bool {
        settings.object(forKey: "libraryCloudEnabled") == nil || settings.bool(forKey: "libraryCloudEnabled")
    }
    static func isDue(_ collection: Collection) -> Bool {
        enabled && Date.now.timeIntervalSince1970 - settings.double(forKey: "cloud-attempt-" + collection.rawValue) >= 60
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func fetch(_ id: CKRecord.ID, database: CKDatabase, metadataOnly: Bool) async throws -> CKRecord? {
        try await withCheckedThrowingContinuation { continuation in
            let reply = FetchReply(continuation)
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            if metadataOnly { operation.desiredKeys = ["digest", "format"] }
            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record): reply.finish(.success(record))
                case .failure(let error as CKError) where error.code == .unknownItem: reply.finish(.success(nil))
                case .failure(let error): reply.finish(.failure(error))
                }
            }
            operation.fetchRecordsResultBlock = { result in
                if case .failure(let error) = result { reply.finish(.failure(error)) }
            }
            database.add(operation)
        }
    }

    func sync(_ collection: Collection, root: URL, resolutions: [LibraryResolution] = [],
              read: () async throws -> [String: LibraryFile],
              validate: ([String: LibraryFile], Set<String>) async throws -> Void,
              apply: ([String: LibraryFile], [String: LibraryFile]) async throws -> Void) async throws -> Int {
        guard Self.enabled else { return 0 }
        let key = collection.rawValue + "|" + root.path
        guard active.insert(key).inserted else { throw AppError(L10n.icloudSyncIsAlreadyRunning) }
        defer { active.remove(key) }
        Self.settings.set(Date.now.timeIntervalSince1970, forKey: "cloud-attempt-" + collection.rawValue)
        let fs = FileManager.default
        try fs.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.path, O_RDONLY)
        guard lock >= 0 else { throw AppError(L10n.cannotOpenICloudSyncStorage) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AppError(L10n.icloudSyncIsAlreadyRunningOnThisDevice) }
        let container = CKContainer(identifier: Self.containerIdentifier)
        guard try await container.accountStatus() == .available else { throw AppError(L10n.signInToSync) }
        let account = try await container.userRecordID().recordName
        let scope = "cloud-library-" + digest(Data((account + "|" + key).utf8))
        let cache = root.appendingPathComponent(scope + ".rimelibrary")
        let database = container.privateCloudDatabase
        let id = CKRecord.ID(recordName: "rime-" + collection.rawValue + "-v1")

        for attempt in 0..<3 {
            try Task.checkCancellation()
            let metadata = try await fetch(id, database: database, metadataOnly: true)
            let local = try await read()
            var remote: [String: LibraryFile] = [:]
            var remoteData: Data?
            let maximumBytes = collection == .learned ? 8 * 1024 * 1024 : LibraryArchive.maximumBytes
            if let metadata {
                guard metadata["format"] as? Int == 1 else { throw AppError(L10n.updateToSyncLibrary) }
                let expected = metadata["digest"] as? String
                if let data = try? Data(contentsOf: cache), digest(data) == expected {
                    remote = try LibraryArchive.decode(data, limit: maximumBytes)
                    remoteData = data
                } else {
                    guard let record = try await fetch(id, database: database, metadataOnly: false),
                          record.recordChangeTag == metadata.recordChangeTag,
                          let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
                        if attempt < 2 { continue }
                        throw AppError(L10n.theICloudLibraryChangedTrySyncingAgain)
                    }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard digest(data) == expected else { throw AppError(L10n.theICloudLibraryDownloadIsIncomplete) }
                    remote = try LibraryArchive.decode(data, limit: maximumBytes)
                    remoteData = data
                }
            }
            let baseline = Self.settings.dictionary(forKey: scope) as? [String: String] ?? [:]
            let effective = RimeLibrary.syncInput(local: local, remote: remote, baseline: baseline)
            var previous: [String: LibraryFile]?
            var mergedTextConflict: LibraryConflict?
            let merged = try RimeLibrary.merge(local: effective, remote: remote, baseline: baseline, resolutions: resolutions,
                didMergeText: { mergedTextConflict = mergedTextConflict ?? $0 }) { path in
                if previous == nil {
                    previous = (try? LibraryArchive.decode(Data(contentsOf: cache, options: .mappedIfSafe), limit: maximumBytes)) ?? [:]
                }
                return previous?[path]
            }
            let localAfter = RimeLibrary.localSyncResult(before: effective, merged: merged)
            try RimeLibrary.verify(merged)
            if localAfter != effective || merged != remote {
                let changed = Set(effective.keys).union(merged.keys).union(remote.keys).filter {
                    localAfter[$0] != effective[$0] || merged[$0] != remote[$0]
                }
                do { try await validate(merged, changed) }
                catch {
                    if let mergedTextConflict { throw mergedTextConflict }
                    throw error
                }
            }
            guard merged.values.reduce(0, { $0 + $1.data.count }) <= maximumBytes else {
                throw AppError(collection == .learned ? L10n.keyboardSyncSizeLimit : L10n.theResourceLibraryExceeds256MB)
            }
            let encoded: Data
            if merged == remote, let remoteData { encoded = remoteData }
            else { encoded = try LibraryArchive.encode(merged, compressed: true, limit: maximumBytes) }
            guard encoded.count <= 48 * 1024 * 1024 else { throw AppError(L10n.cloudRevisionSizeLimit) }
            if merged != remote || metadata == nil {
                let temporary = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try encoded.write(to: temporary, options: .atomic)
                defer { try? fs.removeItem(at: temporary) }
                let record = metadata ?? CKRecord(recordType: "RimeLibrary", recordID: id)
                record["format"] = 1 as CKRecordValue
                record["digest"] = digest(encoded) as CKRecordValue
                record["payload"] = CKAsset(fileURL: temporary)
                do {
                    let result = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                    guard let saved = result.saveResults[id] else { throw AppError(L10n.icloudDidNotConfirmThisRevision) }
                    _ = try saved.get()
                } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 { continue }
            }
            if localAfter != effective {
                do { try await apply(local, localAfter) }
                catch is LearnedSnapshotChanged where attempt < 2 { continue }
            }
            try encoded.write(to: cache, options: .atomic)
            Self.settings.set(RimeLibrary.syncFingerprints(merged), forKey: scope)
            Self.settings.set(Date.now.timeIntervalSince1970, forKey: "cloud-success-" + collection.rawValue)
            return Set(local.keys).union(merged.keys).filter { local[$0] != merged[$0] }.count
        }
        throw AppError(L10n.cloudRevisionConflict)
    }
}
