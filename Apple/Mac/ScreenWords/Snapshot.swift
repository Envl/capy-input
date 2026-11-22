import Foundation

final class Snapshot {
    private static let retention: TimeInterval = 300
    private static let leaseDuration = 12
    let url: URL
    private var visible = Set<Entry>()
    // A visible word stays fresh even when ScreenCaptureKit sends only idle frames.
    private var departed: [Entry: Date] = [:]
    private var nextExpiry = Date.distantFuture
    private var rows = ""
    private var version = UUID().uuidString
    private var dirty = true
    private var lastWrite = Date.distantPast
    private var expiryTimer: Timer?

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("words.tsv")
        clear()
    }

    func replace(_ entries: [Entry], now: Date = Date()) throws {
        let current = Set(entries)
        if current != visible {
            for entry in visible.subtracting(current) { departed[entry] = now }
            for entry in current { departed.removeValue(forKey: entry) }
            visible = current
            dirty = true
        }
        try heartbeat(now: now)
    }

    func heartbeat(now: Date = Date()) throws {
        expiryTimer?.invalidate()
        expiryTimer = nil
        if now >= nextExpiry {
            departed = departed.filter { now.timeIntervalSince($0.value) < Self.retention }
            dirty = true
        }
        if dirty {
            rows = visible.map { "\($0.code)\t\($0.word)\t0\n" }.joined()
            for (entry, lastSeen) in departed {
                rows += "\(entry.code)\t\(entry.word)\t\(Int(lastSeen.timeIntervalSince1970))\n"
            }
            nextExpiry = departed.values.min()?.addingTimeInterval(Self.retention) ?? .distantFuture
            version = UUID().uuidString
            dirty = false
            lastWrite = .distantPast
        }
        guard now.timeIntervalSince(lastWrite) >= 4 else { return }
        let content = "\(Int(now.timeIntervalSince1970) + Self.leaseDuration)\t\(version)\n" + rows
        try Data(content.utf8).write(to: url, options: .atomic)
        lastWrite = now
    }

    // The last snapshot can serve the next composition until its existing lease expires.
    func suspend(now: Date = Date(), keepingSnapshot: Bool) {
        for entry in visible { departed[entry] = now }
        visible.removeAll()
        nextExpiry = .distantPast
        dirty = true
        guard keepingSnapshot, lastWrite != .distantPast else {
            removePublishedSnapshot()
            return
        }
        guard expiryTimer == nil else { return }
        let expiry = Int(lastWrite.timeIntervalSince1970) + Self.leaseDuration
        let deadline = Date(timeIntervalSince1970: TimeInterval(expiry))
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.removePublishedSnapshot()
        }
        expiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func clear() {
        removePublishedSnapshot()
        visible.removeAll()
        departed.removeAll()
        nextExpiry = .distantFuture
        rows = ""
        dirty = true
    }

    private func removePublishedSnapshot() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        try? FileManager.default.removeItem(at: url)
        lastWrite = .distantPast
    }
}
