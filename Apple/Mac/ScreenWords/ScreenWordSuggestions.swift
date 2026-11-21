import AppKit
import Carbon

@MainActor
final class ScreenWordSuggestions: NSObject, ObservableObject {
    static let shared = ScreenWordSuggestions()

    private static let preference = "screenWordSuggestions"
    private static let standaloneID = "local.rime.screenwords"
    private let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/RimeScreenWords", isDirectory: true)
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: preference)
    @Published private(set) var needsPermission = false
    @Published var error: String?
    private var cache: Snapshot?
    private var monitor: CompositionMonitor?
    private var reader: ScreenReader?
    private var session = UUID()
    private var timer: Timer?
    private var sessionActive = true

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeIfEnabled),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(focusChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(focusChanged),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResigned),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionResumed),
            name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        resumeIfEnabled()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try requireStandaloneClosed()
                // Validate and install the translator after screen recording is authorized.
                isEnabled = true
                needsPermission = !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess()
                if !needsPermission { try arm() }
                UserDefaults.standard.set(true, forKey: Self.preference)
            } catch { fail(error) }
        } else {
            disarm()
            isEnabled = false
            needsPermission = false
            UserDefaults.standard.set(false, forKey: Self.preference)
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resumeIfEnabled() {
        guard isEnabled, monitor == nil else { return }
        needsPermission = !CGPreflightScreenCaptureAccess()
        guard !needsPermission else { return }
        do { try arm() }
        catch { fail(error) }
    }

    private func requireStandaloneClosed() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.standaloneID).isEmpty else {
            throw AppError(L10n.screenWordsCloseStandalone)
        }
    }

    private func arm() throws {
        guard monitor == nil else { return }
        try requireStandaloneClosed()
        let redeploy = try ScreenWordSetup.install()
        let cache = try Snapshot(directory: cacheDirectory)
        monitor = try CompositionMonitor(cacheDirectory: cacheDirectory) { [weak self] in
            self?.compositionChanged()
        }
        self.cache = cache
        if redeploy { SquirrelMaintenance.reload(automatic: true) }
    }

    @objc private func sessionResigned() {
        sessionActive = false
        focusChanged()
        cache?.clear()
    }

    @objc private func sessionResumed() { sessionActive = true }

    @objc private func focusChanged() {
        monitor?.reset()
        endComposition()
    }

    @objc private func inputSourceChanged() {
        guard SquirrelMaintenance.isSelected != true else { return }
        focusChanged()
        if monitor != nil { SquirrelMaintenance.flush(automatic: true) }
    }

    @objc private func appTerminated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == SquirrelMaintenance.bundleID { focusChanged() }
    }

    @objc private func appLaunched(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if app?.bundleIdentifier == Self.standaloneID && monitor != nil {
            fail(AppError(L10n.screenWordsCloseStandalone))
        }
    }

    private var canCapture: Bool {
        sessionActive && !IsSecureEventInputEnabled() && SquirrelMaintenance.isSelected == true
            && monitor?.isComposing == true
    }

    private func compositionChanged() {
        guard canCapture else { endComposition(); return }
        guard reader == nil else { return }
        let id = UUID()
        session = id
        let capture = ScreenReader(update: { [weak self] entries in
            guard let self, self.session == id else { return }
            guard self.canCapture else { self.endComposition(); return }
            do { try self.cache?.replace(entries) }
            catch { self.fail(error) }
        }, status: { [weak self] count, error in
            guard let self, self.session == id, count == 0, let error else { return }
            self.fail(error)
        })
        reader = capture
        do { try cache?.heartbeat() } catch { fail(error); return }
        capture.refresh()
        let clock = Timer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(clock, forMode: .common)
        timer = clock
    }

    @objc private func screensChanged() { reader?.refresh() }

    @objc private func tick() {
        guard canCapture else { endComposition(); return }
        do { try cache?.heartbeat() }
        catch { fail(error) }
    }

    private func endComposition() {
        guard let reader else { return }
        session = UUID()
        self.reader = nil
        timer?.invalidate()
        timer = nil
        reader.stop()
        cache?.suspend()
    }

    func disarm() {
        monitor?.stop()
        monitor = nil
        endComposition()
        cache?.clear()
        cache = nil
    }

    private func fail(_ error: Error) {
        setEnabled(false)
        self.error = error.localizedDescription
    }
}
