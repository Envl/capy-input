import Foundation
import CryptoKit

struct RemoteFile: Codable { let path: String; let digest: String; let size: Int }

struct DictionarySync {
    let server: URL
    let key: String
    let root: URL
    private let fs = FileManager.default
    private let limit = 8 * 1024 * 1024
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func valid(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,96}/[A-Za-z0-9_.-]{1,96}\.userdb\.txt$"#, options: .regularExpression) != nil
    }
    private func location(_ name: String) throws -> URL {
        guard valid(name) else { throw AppError(L10n.invalidSnapshotName) }
        let file = root.appendingPathComponent(name)
        guard file.resolvingSymlinksInPath().standardizedFileURL.path == root.resolvingSymlinksInPath().appendingPathComponent(name).standardizedFileURL.path else {
            throw AppError(L10n.cannotSyncThroughASymbolicLink)
        }
        return file
    }
    private func validate(_ bytes: Data, name: String) throws {
        let expected = URL(fileURLWithPath: name).deletingPathExtension().deletingPathExtension().lastPathComponent
        guard let text = String(data: bytes, encoding: .utf8) else { throw AppError(L10n.invalidRimeDictionaryEncoding) }
        let prefix = "#@/db_name\t"
        let names = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }
        guard names.count == 1, names[0].dropFirst(prefix.count) == expected else {
            throw AppError(L10n.dictionaryNameDoesNotMatchItsSnapshotFile)
        }
    }
    private func request(_ path: String = "", method: String = "GET", body: Data? = nil, base: String? = nil) async throws -> Data {
        var endpoint = server.appendingPathComponent("v1/files")
        if !path.isEmpty { endpoint.appendPathComponent(path) }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        request.httpMethod = method
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue(base, forHTTPHeaderField: "X-Base-Digest")
        request.httpBody = body
        // Never forward credentials or snapshots through a redirect.
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirect())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 409 { throw AppError(L10n.snapshotConflict) }
            if status == 401 { throw AppError(L10n.theServerRejectedThisSyncKey) }
            throw AppError(AppError.httpMessage(status: status))
        }
        return data
    }
    private func read(_ url: URL) throws -> Data? {
        guard fs.fileExists(atPath: url.path) else { return nil }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard info.isRegularFile == true, let size = info.fileSize, size <= limit, size > 0 else {
            throw AppError(L10n.snapshotSize(url.lastPathComponent))
        }
        return try Data(contentsOf: url)
    }
    private var stateKey: String {
        // A trailing slash addresses the same vault. Preserve the baseline of
        // older clients that paired with that spelling of the endpoint.
        let address = server.absoluteString
        let base = address.hasSuffix("/") ? String(address.dropLast()) : address
        func scope(_ address: String) -> String {
            "dictionary-sync-" + hash(Data((address + "|" + key + "|" + root.path).utf8))
        }
        func exists(_ id: String) -> Bool {
            Self.settings.object(forKey: id) != nil || UserDefaults.standard.object(forKey: id) != nil ||
            Self.settings.object(forKey: id + "-last-success") != nil || UserDefaults.standard.object(forKey: id + "-last-success") != nil
        }
        let canonical = scope(base)
        if exists(canonical) { return canonical }
        let legacy = scope(base + "/")
        return exists(legacy) ? legacy : canonical
    }

    var lastSuccessKey: String { stateKey + "-last-success" }

    static var settings: UserDefaults {
        #if os(iOS)
        return InputProfile.defaults
        #else
        return .standard
        #endif
    }

    static let defaultServer: String = {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CapySyncServerURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return configured.hasPrefix("$(") ? "" : configured
    }()
    var isConfigured: Bool {
        let local = ["localhost","127.0.0.1","::1","[::1]"].contains(server.host?.lowercased() ?? "")
        return (server.scheme == "https" || (local && server.scheme == "http")) && server.host != nil &&
            server.user == nil && server.password == nil && server.query == nil && server.fragment == nil &&
            key.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil
    }

    var autoSyncDue: Bool {
        Date.now.timeIntervalSince1970 - Self.settings.double(forKey: lastSuccessKey) >= 60
    }

    func run(beforeTransfer: () async throws -> Void = {}, mergeDownloads: () async throws -> Void = {}) async throws -> Int {
        guard isConfigured else {
            throw AppError(L10n.invalidServerCredentials)
        }
        // The host and the keyboard can wake at the same time. The directory
        // lock also releases automatically if iOS terminates either process.
        try fs.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.path, O_RDONLY)
        guard lock >= 0 else { throw AppError(L10n.cannotOpenTheSyncFolder) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AppError(L10n.dictionarySyncIsAlreadyRunning) }
        try Task.checkCancellation()
        try await beforeTransfer()
        let stateKey = self.stateKey
        var baseline = (Self.settings.dictionary(forKey: stateKey) ?? UserDefaults.standard.dictionary(forKey: stateKey)) as? [String:String] ?? [:]
        let listing = try await request()
        var remote = [String:RemoteFile]()
        for entry in try JSONDecoder().decode([RemoteFile].self, from: listing) {
            guard valid(entry.path), entry.size > 0, entry.size <= limit, remote[entry.path] == nil else { throw AppError(L10n.invalidServerManifest) }
            remote[entry.path] = entry
        }
        var names = Set(remote.keys)
        for dir in try fs.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isSymbolicLinkKey], options: .skipsHiddenFiles) {
            let info = try dir.resourceValues(forKeys: [.isDirectoryKey,.isSymbolicLinkKey])
            if info.isDirectory != true || info.isSymbolicLink == true { continue }
            for file in try fs.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                let path = dir.lastPathComponent + "/" + file.lastPathComponent
                if valid(path) { names.insert(path) }
            }
        }
        let pendingMerge = stateKey + "-pending-merge"
        var transfers = 0
        for name in names.sorted() {
            let url = try location(name)
            let localData = try read(url)
            let localHash = localData.map(hash)
            let cloud = remote[name]?.digest
            if localHash != cloud {
                if let localData, cloud == nil || cloud == baseline[name] {
                    try validate(localData, name: name)
                    _ = try await request(name, method: "PUT", body: localData, base: cloud ?? "new")
                    baseline[name] = localHash
                } else if let cloud {
                    let incoming = try await request(name)
                    guard incoming.count <= limit, hash(incoming) == cloud else { throw AppError(L10n.remoteSnapshotChangedRetrySync) }
                    try validate(incoming, name: name)
                    var result = incoming
                    if let localData, localHash != baseline[name] {
                        let filename = url.lastPathComponent
                        let dictionaryName = String(filename.dropLast(".userdb.txt".count))
                        let local = try LearnedDictionary(data: localData, expectedName: dictionaryName)
                        let remote = try LearnedDictionary(data: incoming, expectedName: dictionaryName)
                        let owner = url.deletingLastPathComponent().lastPathComponent
                        result = try LearnedDictionary.merged([local, remote]).encoded(user: owner)
                        guard result.count <= limit else { throw AppError(L10n.snapshotSize(filename)) }
                        if result != incoming {
                            _ = try await request(name, method: "PUT", body: result, base: cloud)
                        }
                    }
                    try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard try read(location(name)).map(hash) == localHash else { throw AppError(L10n.localSnapshotChangedRetrySync) }
                    Self.settings.set(true, forKey: pendingMerge)
                    try result.write(to: url, options: .atomic)
                    baseline[name] = hash(result)
                }
                transfers += 1
            } else { baseline[name] = cloud }
            Self.settings.set(baseline, forKey: stateKey)
        }
        if Self.settings.bool(forKey: pendingMerge) {
            try await mergeDownloads()
            Self.settings.removeObject(forKey: pendingMerge)
        }
        Self.settings.set(Date.now.timeIntervalSince1970, forKey: lastSuccessKey)
        return transfers
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
