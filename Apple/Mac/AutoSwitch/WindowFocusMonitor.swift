import AppKit
import ApplicationServices

struct AXWindowToken: Hashable {
    let pid: pid_t
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(CFHash(element))
    }
}

struct WindowFocus: Equatable {
    let bundleID: String
    let pid: pid_t
    let window: AXWindowToken?
}

@MainActor
final class WindowFocusMonitor: NSObject {
    private let onFocusChange: (WindowFocus) -> Void
    private let onAppTerminated: (pid_t) -> Void
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var lastFocus: WindowFocus?

    init(
        onFocusChange: @escaping (WindowFocus) -> Void,
        onAppTerminated: @escaping (pid_t) -> Void
    ) {
        self.onFocusChange = onFocusChange
        self.onAppTerminated = onAppTerminated
        super.init()
    }

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            handleActivation(frontmost)
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        detachObserver()
        lastFocus = nil
    }

    func refreshAccessibility() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        if AXIsProcessTrusted() {
            if observedPID != frontmost.processIdentifier {
                attachObserver(for: frontmost.processIdentifier)
            }
            emitCurrentFocus(for: frontmost)
        } else {
            detachObserver()
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        handleActivation(app)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if observedPID == pid { detachObserver() }
        if lastFocus?.pid == pid { lastFocus = nil }
        onAppTerminated(pid)
    }

    private func handleActivation(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if AXIsProcessTrusted() {
            attachObserver(for: pid)
        } else {
            detachObserver()
        }
        emitCurrentFocus(for: app)
    }

    private func attachObserver(for pid: pid_t) {
        if observedPID == pid && observer != nil { return }
        detachObserver()

        var newObserver: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<WindowFocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                monitor.handleWindowNotification()
            }
        }, &newObserver)
        guard status == .success, let newObserver else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(newObserver, appElement, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)

        observer = newObserver
        observedPID = pid
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
    }

    private func handleWindowNotification() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == observedPID else { return }
        emitCurrentFocus(for: frontmost)
    }

    private func emitCurrentFocus(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier ?? "pid:\(pid)"
        let window = AXIsProcessTrusted() ? focusedWindow(for: pid) : nil
        let focus = WindowFocus(bundleID: bundleID, pid: pid, window: window)
        guard focus != lastFocus else { return }
        lastFocus = focus
        onFocusChange(focus)
    }

    private func focusedWindow(for pid: pid_t) -> AXWindowToken? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return AXWindowToken(pid: pid, element: value as! AXUIElement)
        }
        value = nil
        if AXUIElementCopyAttributeValue(appElement, kAXMainWindowAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            return AXWindowToken(pid: pid, element: value as! AXUIElement)
        }
        return nil
    }
}
