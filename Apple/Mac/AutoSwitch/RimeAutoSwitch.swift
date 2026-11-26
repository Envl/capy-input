import AppKit
import ApplicationServices
import Carbon

@MainActor
final class RimeAutoSwitch: NSObject, ObservableObject {
    static let shared = RimeAutoSwitch()

    enum InputMode: String {
        case english = "en"
        case chinese = "zh"

        var wireValue: String { self == .english ? "1" : "0" }
        init?(wireValue: String) {
            switch wireValue {
            case "1": self = .english
            case "0": self = .chinese
            default: return nil
            }
        }
    }

    private static let preferenceKey = "rimeAutoSwitch"
    private static let appModesKey = "rimeAutoSwitchAppModes"
    private static let maxWindowEntries = 512

    private let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/CapyAutoSwitch", isDirectory: true)
    private var enabledURL: URL { cacheDirectory.appendingPathComponent("enabled") }
    private var targetURL: URL { cacheDirectory.appendingPathComponent("target") }
    private var stateURL: URL { cacheDirectory.appendingPathComponent("state") }

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: preferenceKey)
    @Published private(set) var needsAccessibilityPermission = false
    @Published var error: String?

    private let sessionID = UUID().uuidString.prefix(8)
    private var targetSeq: UInt64 = 0
    private var lastStateNonce: String?
    private var currentFocus: WindowFocus?
    private var windowModes: [AXWindowToken: InputMode] = [:]
    private var appModes: [String: InputMode] = [:]
    private var windowMonitor: WindowFocusMonitor?
    private var stateSource: DispatchSourceFileSystemObject?

    private override init() {
        super.init()
        loadPersistedAppModes()
    }

    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
        if isEnabled {
            do { try arm(promptForAccessibility: false) }
            catch { fail(error) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try arm(promptForAccessibility: true)
                isEnabled = true
                UserDefaults.standard.set(true, forKey: Self.preferenceKey)
            } catch {
                fail(error)
            }
        } else {
            disarm()
            isEnabled = false
            needsAccessibilityPermission = false
            UserDefaults.standard.set(false, forKey: Self.preferenceKey)
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func disarm() {
        windowMonitor?.stop()
        windowMonitor = nil
        stateSource?.cancel()
        stateSource = nil
        currentFocus = nil
        lastStateNonce = nil
        try? FileManager.default.removeItem(at: enabledURL)
        try? FileManager.default.removeItem(at: targetURL)
        try? FileManager.default.removeItem(at: stateURL)
    }

    private func arm(promptForAccessibility: Bool) throws {
        if windowMonitor != nil { return }
        let redeploy = try AutoSwitchSetup.install()
        try prepareCacheDirectory()
        startStateWatcher()

        let trusted: Bool
        if promptForAccessibility && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        needsAccessibilityPermission = !trusted

        let monitor = WindowFocusMonitor(
            onFocusChange: { [weak self] focus in
                self?.handleFocusChange(focus)
            },
            onAppTerminated: { [weak self] pid in
                self?.handleAppTerminated(pid)
            }
        )
        windowMonitor = monitor
        monitor.start()

        if redeploy {
            SquirrelMaintenance.reload(automatic: true)
        }
    }

    private func prepareCacheDirectory() throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: targetURL)
        try Data().write(to: enabledURL, options: .atomic)
    }

    private func startStateWatcher() {
        let fd = open(cacheDirectory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            self?.readStateUpdate()
        }
        stateSource = source
        source.resume()
    }

    private func handleFocusChange(_ focus: WindowFocus) {
        currentFocus = focus
        let desired = focus.window.flatMap { windowModes[$0] } ?? appModes[focus.bundleID]
        writeTarget(mode: desired)
    }

    private func handleAppTerminated(_ pid: pid_t) {
        windowModes = windowModes.filter { $0.key.pid != pid }
    }

    private func readStateUpdate() {
        guard let text = try? String(contentsOf: stateURL, encoding: .utf8) else { return }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 1)
        guard parts.count == 2 else { return }
        let modeString = String(parts[0])
        let nonce = String(parts[1])
        guard nonce != lastStateNonce, let mode = InputMode(wireValue: modeString) else { return }
        lastStateNonce = nonce

        guard let focus = currentFocus else { return }
        if let window = focus.window {
            if windowModes.count >= Self.maxWindowEntries && windowModes[window] == nil {
                windowModes.removeAll(keepingCapacity: true)
            }
            windowModes[window] = mode
        }
        if appModes[focus.bundleID] != mode {
            appModes[focus.bundleID] = mode
            savePersistedAppModes()
        }
        // Keep target in sync so any newly created Rime session in this window sees the latest mode.
        writeTarget(mode: mode)
    }

    private func writeTarget(mode: InputMode?) {
        targetSeq += 1
        let value = mode?.wireValue ?? "-"
        let content = "\(sessionID):\(targetSeq)\t\(value)\n"
        try? Data(content.utf8).write(to: targetURL, options: .atomic)
    }

    @objc private func appDidBecomeActive() {
        guard isEnabled else { return }
        let trusted = AXIsProcessTrusted()
        needsAccessibilityPermission = !trusted
        windowMonitor?.refreshAccessibility()
    }

    @objc private func inputSourceChanged() {
        guard isEnabled, SquirrelMaintenance.isSelected != true else { return }
        SquirrelMaintenance.flush(automatic: true)
    }

    private func loadPersistedAppModes() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.appModesKey) as? [String: String] else { return }
        appModes = raw.compactMapValues(InputMode.init(rawValue:))
    }

    private func savePersistedAppModes() {
        let raw = appModes.mapValues(\.rawValue)
        UserDefaults.standard.set(raw, forKey: Self.appModesKey)
    }

    private func fail(_ error: Error) {
        setEnabled(false)
        self.error = error.localizedDescription
    }
}
