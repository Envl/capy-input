import Foundation
import CryptoKit

// A versioned snapshot keeps resource dependencies in one revision.
struct LibraryFile: Codable, Equatable {
    var data: Data
    var bundled: Bool
}

struct LibraryDocument: Codable {
    let version: Int
    let id: UUID
    var files: [String: LibraryFile]
    init() { version = 1; id = UUID(); files = [:] }
}

struct LibraryConflict: LocalizedError, Equatable {
    let path: String
    let local: String?
    let shared: String?
    var errorDescription: String? { L10n.bothDevicesChanged(path) }
}

struct LibraryResolution {
    let conflict: LibraryConflict
    let useLocal: Bool
}

/// RimeScreenWords appends one UTF-8 code/word pair per line and tails the file
/// by byte offset. Byte identity matches the Lua reader, including for Unicode.
struct SelectedWords {
    static func recognizes(_ path: String) -> Bool {
        path.hasPrefix("rime-jit-selected-") && path.range(of: #"\Arime-jit-selected-[A-Za-z0-9_-]+\.tsv\z"#, options: .regularExpression) != nil
    }

    let rows: Set<Data>
    init?(_ file: LibraryFile?) {
        guard let file, !file.bundled, file.data.isEmpty || file.data.last == 10,
              String(data: file.data, encoding: .utf8) != nil else { return nil }
        if file.data.isEmpty { rows = []; return }
        var parsed = Set<Data>()
        for row in file.data.dropLast().split(separator: 10, omittingEmptySubsequences: false) {
            guard let tab = row.firstIndex(of: 9), tab != row.startIndex,
                  row[..<tab].allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
            let word = row.suffix(from: row.index(after: tab))
            guard !word.isEmpty, word.allSatisfy({ $0 >= 32 && $0 != 127 }) else { return nil }
            parsed.insert(Data(row))
        }
        rows = parsed
    }

    static func encode(_ rows: Set<Data>, appendingTo prefix: Data = Data()) -> Data {
        var result = prefix
        for row in rows.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            result.append(row)
            result.append(10)
        }
        return result
    }

    var fingerprint: String {
        "selected:" + SHA256.hash(data: Self.encode(rows)).map { String(format: "%02x", $0) }.joined()
    }
}

struct RimeLibrary {
    let stock: URL?
    let profile: URL
    let learned: URL?
    var runtime: URL? = nil
    private let fs = FileManager.default
    static let documentName = "Rime Library.rimelibrary"
    static let completeMarker = "library-generation"
    static let exclusionsName = "library-exclusions.plist"

    static func portable(_ path: String) -> Bool {
        let parts = path.components(separatedBy: "/")
        let lower = parts.map { $0.lowercased() }
        guard !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") || $0.contains("\\") || $0.contains("\0") }),
              !lower.contains(where: { ["build","sync","trash","logs","licenses","learned"].contains($0) || $0.hasSuffix(".userdb") }),
              let name = lower.last, !["installation.yaml","user.yaml","squirrel.yaml","squirrel.custom.yaml","weasel.yaml","weasel.custom.yaml","gestures.tsv","english.txt"].contains(name),
              !name.hasSuffix(".userdb.txt") else { return false }
        return ["yaml","yml","lua","txt","tsv","json","ocd","ocd2","gram","db","bin","stabledb","reverse","prism"].contains((name as NSString).pathExtension)
    }

    static func isSnapshot(_ path: String) -> Bool {
        path.range(of: #"\ALearned/[A-Za-z0-9_-]{1,96}/[A-Za-z0-9_.-]{1,96}\.userdb\.txt\z"#, options: .regularExpression) != nil
    }

    static func checked(_ root: URL, _ path: String) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.resolvingSymlinksInPath().path == url.path else {
            throw AppError(L10n.unsafeResourcePath(path))
        }
        // resolvingSymlinksInPath may leave a nonexistent child unresolved.
        var parent = base
        for part in path.components(separatedBy: "/") {
            parent.appendPathComponent(part)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: parent.path)) != nil {
                throw AppError(L10n.linkedResourcePath(path))
            }
        }
        return url
    }

    static func scan(_ root: URL?, snapshots: Bool = false) throws -> [String: URL] {
        guard let root, FileManager.default.fileExists(atPath: root.path) else { return [:] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var failure: Error?
        guard let items = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
            throw AppError(L10n.cannotOpenResource(root.lastPathComponent))
        }
        var files = [String: URL]()
        for case let url as URL in items {
            let values = try url.resourceValues(forKeys: keys)
            let path = url.standardizedFileURL.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
            if values.isSymbolicLink == true || (values.isDirectory == true && (snapshots ? path.contains("/") : !portable(path + "/probe.yaml"))) {
                items.skipDescendants()
            } else if values.isRegularFile == true {
                let name = snapshots ? "Learned/" + path : path
                if snapshots ? isSnapshot(name) : portable(name) { files[name] = url }
            }
        }
        if let failure { throw failure }
        return files
    }

    /// User-selected words are shared by the phone keyboard and the Mac Lua reader.
    static func selectedWordTables(at root: URL) throws -> [String: LibraryFile] {
        let fs = FileManager.default
        guard fs.fileExists(atPath: root.path) else { return [:] }
        var files = [String: LibraryFile]()
        for name in try fs.contentsOfDirectory(atPath: root.path) where SelectedWords.recognizes(name) {
            let url = try checked(root, name)
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 64 * 1024 * 1024 else {
                throw AppError(L10n.invalidResource(name))
            }
            files[name] = LibraryFile(data: try Data(contentsOf: url), bundled: false)
        }
        return files
    }

    static func validateWordTables(_ files: [String: LibraryFile]) throws {
        for (name, file) in files {
            guard SelectedWords.recognizes(name), SelectedWords(file) != nil else {
                throw AppError(L10n.invalidResource(name))
            }
        }
    }

    static func wordTableUpdates(at folder: URL, before: [String: LibraryFile], after: [String: LibraryFile]) throws -> [URL: Data?] {
        try validateWordTables(after)
        guard try selectedWordTables(at: folder) == before else { throw AppError(L10n.theLibraryChangedWhileSyncingTryAgain) }
        var updates = [URL: Data?]()
        for name in Set(before.keys).union(after.keys) where before[name] != after[name] {
            updates.updateValue(after[name]?.data, forKey: try checked(folder, name))
        }
        return updates
    }

    static func isUserTable(_ path: String) -> Bool {
        !path.contains("/") && path.hasSuffix(".tsv") && portable(path)
    }

    func sources() throws -> [String: URL] {
        let complete = fs.fileExists(atPath: profile.appendingPathComponent(Self.completeMarker).path)
        var files = try Self.scan(complete ? nil : stock).merging(Self.scan(profile)) { _, override in override }
            .merging(Self.scan(learned, snapshots: true)) { _, file in file }
        let exclusions = (try? Data(contentsOf: profile.appendingPathComponent(Self.exclusionsName)))
            .flatMap { try? PropertyListDecoder().decode(Set<String>.self, from: $0) } ?? []
        for path in exclusions { files.removeValue(forKey: path) }
        if let runtime, fs.fileExists(atPath: runtime.path) {
            for url in try fs.contentsOfDirectory(at: runtime, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) {
                let name = url.lastPathComponent
                if Self.isUserTable(name), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    files[name] = try Self.checked(runtime, name)
                }
            }
        }
        return files
    }

    func inventory() throws -> [String: LibraryFile] {
        let defaults = try Self.scan(stock)
        var result = [String: LibraryFile]()
        for (path, url) in try sources() {
            let data = try Data(contentsOf: url)
            let bundled = defaults[path].map { $0 == url || (try? Data(contentsOf: $0, options: .mappedIfSafe)) == data } ?? false
            result[path] = LibraryFile(data: data, bundled: bundled)
        }
        return result
    }

    static func fingerprint(_ file: LibraryFile) -> String {
        (file.bundled ? "stock:" : "user:") + SHA256.hash(data: file.data).map { String(format: "%02x", $0) }.joined()
    }

    static func syncInput(local: [String: LibraryFile], remote: [String: LibraryFile], baseline: [String: String]) -> [String: LibraryFile] {
        var effective = local
        for (path, file) in local {
            // A complete profile also contains stock files copied from the other
            // frontend. They can be recognized by content on a fresh install.
            if let stock = remote[path], stock.bundled, file.bundled || file.data == stock.data {
                effective[path] = stock
            } else if !file.bundled, let old = baseline[path], old.hasPrefix("stock:") {
                let bundled = LibraryFile(data: file.data, bundled: true)
                if fingerprint(bundled) == old { effective[path] = bundled }
            }
        }
        return effective
    }

    static func syncFingerprints(_ files: [String: LibraryFile]) -> [String: String] {
        var hashes = files.mapValues(fingerprint)
        for (path, file) in files where SelectedWords.recognizes(path) {
            if let selected = SelectedWords(file) { hashes[path] = selected.fingerprint }
        }
        return hashes
    }

    /// Retain the live reader's byte offset when the merge only adds selections.
    static func localSyncResult(before: [String: LibraryFile], merged: [String: LibraryFile]) -> [String: LibraryFile] {
        var result = merged
        for (path, file) in merged where before[path] != file && SelectedWords.recognizes(path) {
            guard let original = before[path], let local = SelectedWords(original), let target = SelectedWords(file),
                  local.rows.isSubset(of: target.rows) else { continue }
            result[path] = LibraryFile(data: SelectedWords.encode(target.rows.subtracting(local.rows), appendingTo: original.data), bundled: false)
        }
        return result
    }

    // Stock resources can differ by frontend. A user's override always wins
    // over a factory copy, including when a second installation first joins.
    static func merge(local: [String: LibraryFile], remote: [String: LibraryFile], baseline: [String: String],
                      resolutions: [LibraryResolution] = [], didMergeText: (LibraryConflict) -> Void = { _ in },
                      previousFile: (String) -> LibraryFile? = { _ in nil }) throws -> [String: LibraryFile] {
        var merged = remote
        for path in Set(local.keys).union(remote.keys).union(baseline.keys).sorted() {
            let l = local[path], r = remote[path], old = baseline[path]
            if l == r { continue }
            let lh = l.map(fingerprint), rh = r.map(fingerprint)
            let selected = SelectedWords.recognizes(path)
            let localWords = selected ? SelectedWords(l) : nil
            let remoteWords = selected ? SelectedWords(r) : nil
            if let localWords, let remoteWords, localWords.rows == remoteWords.rows { continue }
            if old == nil {
                if l == nil { continue }
                if r == nil || (r?.bundled == true && l?.bundled == false) { merged[path] = l; continue }
                if l?.bundled == true { continue }
            } else {
                if lh == old || localWords?.fingerprint == old { continue }
                if rh == old || remoteWords?.fingerprint == old { merged[path] = l; continue }
                if l?.bundled == true && r?.bundled == true { continue }
            }
            // Concurrent factory updates must not displace a user override.
            if let l, let r, l.bundled != r.bundled {
                merged[path] = l.bundled ? r : l
                continue
            }
            if isSnapshot(path), l == nil || r == nil {
                // Word deletions live inside snapshots as tombstones. Retain the
                // updated snapshot if the other peer removed its older file.
                merged[path] = l ?? r
                continue
            }
            if let localWords, let remoteWords {
                var rows = localWords.rows.union(remoteWords.rows)
                // Use the last successfully synced archive to distinguish a deletion
                // from a new entry. Older clients stored the raw file fingerprint.
                if let old, let baseFile = previousFile(path), let base = SelectedWords(baseFile),
                   base.fingerprint == old || fingerprint(baseFile) == old {
                    rows.subtract(base.rows.subtracting(localWords.rows.intersection(remoteWords.rows)))
                }
                if rows != remoteWords.rows {
                    merged[path] = LibraryFile(data: SelectedWords.encode(rows), bundled: false)
                }
                continue
            }
            if isSnapshot(path), let l, let r {
                let a = try LearnedDictionary(data: l.data), b = try LearnedDictionary(data: r.data)
                let dictionary = try LearnedDictionary.merged([a, b])
                let owner = path.components(separatedBy: "/")[1]
                merged[path] = LibraryFile(data: dictionary.encoded(user: owner), bundled: false)
                continue
            }
            let conflict = LibraryConflict(path: path, local: lh, shared: rh)
            if let resolution = resolutions.first(where: { $0.conflict == conflict }) {
                merged[path] = resolution.useLocal ? l : r
            } else if let l, let r, let old, let base = previousFile(path), fingerprint(base) == old,
                      let combined = mergeText(path: path, base: base, local: l, remote: r) {
                didMergeText(conflict)
                merged[path] = combined
            } else { throw conflict }
        }
        return merged
    }

    /// Merge separate line edits against the last synced file. Ambiguous edits
    /// (including simultaneous insertions at one boundary) need a choice.
    private static func mergeText(path: String, base: LibraryFile, local: LibraryFile, remote: LibraryFile) -> LibraryFile? {
        guard ["yaml", "yml", "lua", "json", "txt", "tsv"].contains((path as NSString).pathExtension),
              !SelectedWords.recognizes(path), !isSnapshot(path) else { return nil }
        func lines(_ file: LibraryFile) -> [Substring.UTF8View]? {
            guard file.data.count <= 512 * 1024, let text = String(data: file.data, encoding: .utf8),
                  !text.contains("\0") else { return nil }
            return text.utf8.split(separator: 10, omittingEmptySubsequences: false)
        }
        guard let original = lines(base), let left = lines(local), let right = lines(remote) else { return nil }
        func edit(_ updated: [Substring.UTF8View]) -> (range: Range<Int>, replacement: ArraySlice<Substring.UTF8View>) {
            let limit = min(original.count, updated.count)
            var start = 0, suffix = 0
            while start < limit && original[start].elementsEqual(updated[start]) { start += 1 }
            while suffix < limit - start &&
                    original[original.count - suffix - 1].elementsEqual(updated[updated.count - suffix - 1]) {
                suffix += 1
            }
            return (start..<(original.count - suffix), updated[start..<(updated.count - suffix)])
        }
        let edits = [edit(left), edit(right)].sorted { $0.range.lowerBound < $1.range.lowerBound }
        let first = edits[0].range, second = edits[1].range
        guard first.upperBound < second.lowerBound ||
                (first.upperBound == second.lowerBound && !first.isEmpty && !second.isEmpty) else { return nil }
        var combined = original
        for edit in edits.reversed() { combined.replaceSubrange(edit.range, with: edit.replacement) }
        return LibraryFile(data: Data(combined.joined(separator: [10])), bundled: false)
    }

    static func verify(_ files: [String: LibraryFile]) throws {
        var names = Set<String>()
        for (path, file) in files {
            guard portable(path) || isSnapshot(path),
                  names.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw AppError(L10n.invalidResource(path))
            }
            if isSnapshot(path) {
                let expected = String((path as NSString).lastPathComponent.dropLast(".userdb.txt".count))
                guard !file.bundled, let text = String(data: file.data, encoding: .utf8),
                      text.split(whereSeparator: \.isNewline).filter({ $0.hasPrefix("#@/db_name\t") }).map(String.init) == ["#@/db_name\t" + expected] else {
                    throw AppError(L10n.invalidLearnedDictionary(path))
                }
            }
        }
    }

}
