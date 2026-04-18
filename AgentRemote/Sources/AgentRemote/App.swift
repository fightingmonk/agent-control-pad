import Cocoa
import ApplicationServices
import CoreGraphics
import os

// MARK: - Response action model

enum ResponseAction: String, CustomStringConvertible {
    case allowOnce    = "allow-once"
    case allowAlways  = "allow-always"
    case deny         = "deny"

    var description: String { rawValue }

    static func from(keyCode: UInt16) -> ResponseAction? {
        switch keyCode {
        case 105: return .allowOnce     // F13
        case 106: return .allowAlways   // F16
        case 64:  return .deny          // F17
        default:  return nil
        }
    }
}

// MARK: - Preferences

class Preferences {
    private static let suiteName = "com.tappister.agentremote"
    private let defaults: UserDefaults

    private static let doubleTapAllowAlwaysKey = "doubleTapAllowAlways"

    var doubleTapAllowAlways: Bool {
        get { defaults.bool(forKey: Self.doubleTapAllowAlwaysKey) }
        set { defaults.set(newValue, forKey: Self.doubleTapAllowAlwaysKey) }
    }

    init() {
        defaults = UserDefaults(suiteName: Self.suiteName) ?? .standard
        // Register defaults — double-tap is on by default
        defaults.register(defaults: [Self.doubleTapAllowAlwaysKey: true])
    }
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let scanner = WindowScanner()
    private let activator = Activator()
    private let prefs = Preferences()
    private let workQueue = DispatchQueue(label: "com.agentremote.work", qos: .userInteractive)

    // Double-tap tracking for F16 (allow always)
    private var lastAllowAlwaysTime: Date?
    private var doubleTapMenuItem: NSMenuItem!

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        checkAccessibility()
        installKeyMonitor()
        log("Ready — F13 (allow once) · F16 (allow always) · F17 (deny)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
    }

    // MARK: Menu bar

    private static let idleIcon = "✦"

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.systemFont(ofSize: 17)
        statusItem.button?.title = Self.idleIcon

        let menu = NSMenu()
        menu.addItem(withTitle: "Agent Remote", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        doubleTapMenuItem = NSMenuItem(title: "Require Double-Tap for Allow Always", action: #selector(toggleDoubleTap), keyEquivalent: "")
        doubleTapMenuItem.target = self
        doubleTapMenuItem.state = prefs.doubleTapAllowAlways ? .on : .off
        menu.addItem(doubleTapMenuItem)

        menu.addItem(.separator())

        let scanItem = NSMenuItem(title: "Diagnostic Scan", action: #selector(diagnosticScan), keyEquivalent: "d")
        scanItem.target = self
        menu.addItem(scanItem)

        let dumpItem = NSMenuItem(title: "Dump Frontmost AX Tree", action: #selector(dumpFrontmost), keyEquivalent: "")
        dumpItem.target = self
        menu.addItem(dumpItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: Accessibility check

    private func checkAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        if trusted {
            log("Accessibility: granted")
        } else {
            log("⚠️  Accessibility permission required — the system prompt should have appeared")
            log("   Go to System Settings → Privacy & Security → Accessibility and enable AgentRemote")
        }
    }

    // MARK: Global key monitor

    private func installKeyMonitor() {
        // Use a CGEvent tap to catch all key events including high F-keys.
        // NSEvent.addGlobalMonitorForEvents misses F13+ on macOS.
        // We use .defaultTap to intercept and swallow F13/F16/F17 — they're
        // dedicated macro pad keys handled exclusively by AgentRemote.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | CGEventMask(NX_SYSDEFINEDMASK)

        // Store self in an Unmanaged pointer so the C callback can reach us
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                // Swallow both keyDown and keyUp for our dedicated F-keys
                guard ResponseAction.from(keyCode: keyCode) != nil else {
                    return Unmanaged.passUnretained(event) // pass through everything else
                }

                if type == .keyDown, let action = ResponseAction.from(keyCode: keyCode) {
                    delegate.handleKeyAction(action)
                }

                return nil // consume the event — AgentRemote owns these keys
            },
            userInfo: refcon
        ) else {
            log("❌ Failed to create CGEvent tap — Accessibility or Input Monitoring permission is likely missing")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("✅ CGEvent tap installed (intercepting F13/F16/F17)")
    }

    // MARK: Double-tap gate

    /// Called from the CGEvent tap. Applies the double-tap guard for allowAlways,
    /// then dispatches to handleAction.
    func handleKeyAction(_ action: ResponseAction) {
        // For non-allowAlways actions, reset the double-tap state and fire immediately
        guard action == .allowAlways else {
            lastAllowAlwaysTime = nil
            handleAction(action)
            return
        }

        // If double-tap is disabled, fire immediately
        guard prefs.doubleTapAllowAlways else {
            handleAction(action)
            return
        }

        let now = Date()
        if let last = lastAllowAlwaysTime, now.timeIntervalSince(last) < 2.0 {
            // Second tap within window — fire and reset
            lastAllowAlwaysTime = nil
            log("⌨️  F16 double-tap confirmed")
            handleAction(action)
        } else {
            // First tap — record time, show hint, wait for second
            lastAllowAlwaysTime = now
            log("⌨️  F16 first tap — tap again within 2s to allow always")
            DispatchQueue.main.async { self.flash("A?") }
        }
    }

    @objc private func toggleDoubleTap() {
        prefs.doubleTapAllowAlways.toggle()
        doubleTapMenuItem.state = prefs.doubleTapAllowAlways ? .on : .off
        log("Double-tap for Allow Always: \(prefs.doubleTapAllowAlways ? "on" : "off")")
    }

    // MARK: Action handler

    private func handleAction(_ action: ResponseAction) {
        workQueue.async { [self] in
            log("⌨️  \(action) triggered — scanning…")

            let candidates = scanner.findCandidates()
            log("   \(candidates.count) candidate(s): \(candidates.map(\.bundleID).joined(separator: ", "))")

            for candidate in candidates {
                log("   → \(candidate.bundleID) (pid \(candidate.pid), \(candidate.category))")

                if let match = scanner.findPrompt(in: candidate, for: action) {
                    log("     Match: \(match)")
                    let ok = activator.execute(match)
                    if ok {
                        log("     ✅ Activated")
                        let icon: String
                        switch action {
                        case .allowOnce:  icon = "Y"
                        case .allowAlways: icon = "A"
                        case .deny:        icon = "N"
                        }
                        DispatchQueue.main.async { self.flash(icon) }
                    } else {
                        log("     ❌ Activation failed")
                        DispatchQueue.main.async { self.flash("⛔") }
                    }
                    return
                }
            }

            // No prompt found via direct detection — try forwarding to VS Code
            // extension which can read terminal buffers that AX can't access.
            if activator.forwardToVSCode(action: action) {
                log("   ➜ Forwarded to VS Code extension")
                DispatchQueue.main.async { self.flash("⇥") }
            } else {
                log("   No prompt found")
                DispatchQueue.main.async { self.flash("—") }
            }
        }
    }

    // MARK: Visual feedback

    private func flash(_ icon: String) {
        statusItem.button?.title = icon
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.statusItem.button?.title = Self.idleIcon
        }
    }

    // MARK: Diagnostics

    @objc private func diagnosticScan() {
        workQueue.async { [self] in
            log("── Diagnostic scan ──")
            let candidates = scanner.findCandidates()
            if candidates.isEmpty {
                log("   No known agent apps have visible windows")
                return
            }
            for c in candidates {
                log("   • \(c.bundleID)  pid=\(c.pid)  category=\(c.category)")

                // Try each action and report what we'd find
                for action in [ResponseAction.allowOnce, .allowAlways, .deny] {
                    if let match = scanner.findPrompt(in: c, for: action) {
                        log("     [\(action)] → \(match)")
                    }
                }
            }
            log("── End scan ──")
        }
    }

    @objc private func dumpFrontmost() {
        workQueue.async { [self] in
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bid = front.bundleIdentifier else {
                log("No frontmost app")
                return
            }
            log("── AX dump: \(bid) (pid \(front.processIdentifier)) ──")
            let axApp = AXUIElementCreateApplication(front.processIdentifier)
            AXTreeDumper.dump(axApp, label: bid, maxDepth: 6)
            log("── End dump ──")
        }
    }

    @objc private func doQuit() {
        NSApp.terminate(nil)
    }

    func log(_ msg: String) {
        print("[AgentRemote] \(msg)")
        appLog.info("\(msg, privacy: .public)")
    }
}

let appLog = Logger(subsystem: "com.tappister.agentremote", category: "main")