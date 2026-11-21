import AppKit
import Carbon

/// sync_user_data and redeploy both destroy Squirrel's live Rime sessions.
/// An idle keyboard can still have marked text. Use the input source, not a
/// timeout since the last keystroke, and fail closed if TIS cannot identify it.
enum SquirrelMaintenance {
    static let bundleID = "im.rime.inputmethod.Squirrel"
    @MainActor static var canRunAutomatically: Bool { isSelected == false }

    @MainActor static var isSelected: Bool? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let identifier = Unmanaged<CFString>.fromOpaque(id).takeUnretainedValue() as String
        guard !identifier.isEmpty else { return nil }
        let bundle = TISGetInputSourceProperty(source, kTISPropertyBundleID).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        return identifier == bundleID || identifier.hasPrefix(bundleID + ".") || bundle == bundleID
    }

    private static let pendingReload = "squirrelPendingResourceReload"
    private static let pendingMerge = "squirrelPendingDictionaryMerge"

    @MainActor static func merge(automatic: Bool) {
        UserDefaults.standard.set(true, forKey: pendingMerge)
        flush(automatic: automatic)
    }
    @MainActor static func reload(automatic: Bool) {
        UserDefaults.standard.set(true, forKey: pendingReload)
        flush(automatic: automatic)
    }

    @MainActor static func flush(automatic: Bool) {
        guard !automatic || canRunAutomatically else { return }
        if UserDefaults.standard.bool(forKey: pendingReload) {
            DistributedNotificationCenter.default().postNotificationName(.init("SquirrelReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
            UserDefaults.standard.removeObject(forKey: pendingReload)
            // Redeploy can take time; merge on a later safe wake-up.
            return
        }
        if UserDefaults.standard.bool(forKey: pendingMerge) {
            MacDictionarySync.notifySquirrel()
            UserDefaults.standard.removeObject(forKey: pendingMerge)
        }
    }
}

@MainActor
final class MacDictionarySync {
    static let shared = MacDictionarySync()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        syncSavedConfiguration()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncSavedConfiguration() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func syncSavedConfiguration() {
        SquirrelMaintenance.flush(automatic: true)
        Task { await LibraryStatus.shared.sync() }
    }

    nonisolated static func notifySquirrel() {
        DistributedNotificationCenter.default().postNotificationName(.init("SquirrelSyncNotification"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

