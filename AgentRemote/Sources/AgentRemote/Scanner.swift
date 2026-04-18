import Cocoa
import ApplicationServices
import CoreGraphics
import os

private func scanLog(_ msg: String) {
    print("[AgentRemote] \(msg)")
    appLog.info("\(msg, privacy: .public)")
}

// MARK: - App registry

enum AppCategory: String, CustomStringConvertible {
    case gui
    case terminal

    var description: String { rawValue }
}

struct CandidateApp {
    let pid: pid_t
    let bundleID: String
    let category: AppCategory
    let axApp: AXUIElement
}

/// Known agent-hosting apps and their detection strategy.
/// Add new bundle IDs here as you encounter them.
let appRegistry: [String: AppCategory] = [
    // GUI / Electron apps — we walk the AX tree for buttons
    "com.anthropic.claudedesktop":      .gui,
    "com.cursor.Cursor":                .gui,

    // Terminal emulators — we read the text buffer and send keystrokes
    "com.apple.Terminal":               .terminal,
    "com.googlecode.iterm2":            .terminal,
    "com.mitchellh.ghostty":            .terminal,
    "net.kovidgoyal.kitty":             .terminal,
    "dev.warp.Warp-Stable":             .terminal,
    "co.zeit.hyper":                     .terminal,
    "com.github.alacritty":             .terminal,
    "io.alacritty":                     .terminal,
]

// MARK: - Prompt match

/// A virtual key code + description pair for keystroke sequences.
struct Key {
    let code: UInt16
    let label: String

    static let enter     = Key(code: 36, label: "Enter")      // kVK_Return
    static let downArrow = Key(code: 125, label: "Down")       // kVK_DownArrow
    static let y         = Key(code: 16, label: "y")           // kVK_ANSI_Y
    static let a         = Key(code: 0,  label: "a")           // kVK_ANSI_A
    static let n         = Key(code: 45, label: "n")           // kVK_ANSI_N
}

enum PromptMatch: CustomStringConvertible {
    /// A GUI button we can AXPress
    case button(element: AXUIElement, label: String)
    /// A terminal prompt we answer with a keystroke sequence, raising a specific window first
    case terminalKeys(pid: pid_t, window: AXUIElement, keys: [Key])

    var description: String {
        switch self {
        case .button(_, let label):
            return "GUI button \"\(label)\""
        case .terminalKeys(let pid, _, let keys):
            let seq = keys.map(\.label).joined(separator: " → ")
            return "keys [\(seq)] → pid \(pid)"
        }
    }
}

// MARK: - Window scanner

class WindowScanner {

    /// Returns candidate apps ordered by window Z-order (frontmost first),
    /// deduplicated by PID so we only scan each app once.
    func findCandidates() -> [CandidateApp] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        var seen = Set<pid_t>()
        var results: [CandidateApp] = []

        for info in infoList {
            guard let pid   = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,               // normal window layer only
                  !seen.contains(pid)
            else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bid = app.bundleIdentifier
            else { continue }

            guard let cat = appRegistry[bid] else {
                // Uncomment for deep debugging:
                // scanLog("   skip: \(bid) (not in registry)")
                continue
            }

            seen.insert(pid)
            results.append(CandidateApp(
                pid: pid,
                bundleID: bid,
                category: cat,
                axApp: AXUIElementCreateApplication(pid)
            ))
        }

        return results
    }

    /// Search an app's windows for an actionable prompt.
    func findPrompt(in app: CandidateApp, for action: ResponseAction) -> PromptMatch? {
        switch app.category {
        case .gui:      return GUIDetector.find(in: app, action: action)
        case .terminal: return TerminalDetector.find(in: app, action: action)
        }
    }
}

// MARK: - GUI detector (Electron / native apps with AX buttons)

enum GUIDetector {

    // Button-label classification.
    // Order matters: "allow always" must be checked before bare "allow",
    // otherwise "Allow Always" would match the allowOnce bucket.

    static func find(in app: CandidateApp, action: ResponseAction) -> PromptMatch? {
        guard let windows = axWindows(of: app.axApp) else { return nil }
        for window in windows {
            if let match = walkForButton(element: window, action: action, depth: 0) {
                return match
            }
        }
        return nil
    }

    /// Recursively walk the AX tree looking for a button whose title matches
    /// the requested action. Max depth prevents runaway traversals in deep
    /// Electron component trees.
    private static func walkForButton(
        element: AXUIElement,
        action: ResponseAction,
        depth: Int
    ) -> PromptMatch? {
        guard depth < 20 else { return nil }

        // Is this element a button?
        if let role = axString(element, kAXRoleAttribute),
           role == (kAXButtonRole as String) {

            // Check AXTitle and AXDescription — Electron apps are inconsistent
            // about which one carries the visible label
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
                if let label = axString(element, attr), !label.isEmpty {
                    if matches(label: label, action: action) {
                        return .button(element: element, label: label)
                    }
                }
            }

            // Also check AXValue — some toolkits put the label there
            if let label = axString(element, kAXValueAttribute), !label.isEmpty {
                if matches(label: label, action: action) {
                    return .button(element: element, label: label)
                }
            }
        }

        // Recurse into children
        guard let children = axChildren(element) else { return nil }
        for child in children {
            if let match = walkForButton(element: child, action: action, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    /// Test whether a button label matches the requested response action.
    private static func matches(label: String, action: ResponseAction) -> Bool {
        let s = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .allowAlways:
            // Must include "always" alongside an affirmative word
            guard s.contains("always") else { return false }
            return containsAny(s, ["allow", "yes", "trust", "approve", "accept"])

        case .allowOnce:
            // Affirmative, but NOT "always" (to avoid stealing the allowAlways match)
            guard !s.contains("always") else { return false }
            // "once" variant
            if s.contains("once") && containsAny(s, ["allow", "yes", "approve"]) { return true }
            // Bare affirmatives — only match if they are the complete or near-complete label
            // to avoid matching random buttons like "Continue reading"
            let bareAffirmatives = [
                "allow", "yes", "accept", "approve", "run",
                "ok", "confirm", "continue", "proceed",
            ]
            return bareAffirmatives.contains(where: { s == $0 || s.hasPrefix($0 + " ") || s.hasSuffix(" " + $0) })

        case .deny:
            let denyWords = [
                "deny", "reject", "no", "cancel", "block",
                "don't allow", "do not allow", "decline",
                "abort", "refuse", "dismiss",
            ]
            return containsAny(s, denyWords)
        }
    }

    private static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains(where: { haystack.contains($0) })
    }
}

// MARK: - Terminal detector (reads AX text buffer, sends keystroke)

enum TerminalDetector {

    /// Prompt style detected in the terminal.
    private enum PromptStyle {
        /// Claude Code interactive menu: "❯ 1. Yes / 2. Yes, and don't ask again / 3. No"
        case interactiveMenu
        /// Classic y/n/a text prompt
        case textPrompt
    }

    /// Regex patterns for the interactive menu style (Claude Code).
    private static let menuPatterns: [String] = [
        // "Do you want to proceed?" followed by numbered Yes/No options
        "Do you want to proceed\\?\\n.*\\d+\\.\\s*(Yes|No)",
        // Arrow-selected menu with Yes/No options
        "❯\\s*\\d+\\.\\s*(Yes|No)",
    ]

    /// Regex patterns for classic y/n/a text prompts.
    private static let textPatterns: [String] = [
        "(?i)\\b(allow|approve|permit|run)\\b.*\\?",
        "(?i)\\[(y|Y)/(n|N)/(a|A)\\]",
        "(?i)\\(y\\).*\\(n\\).*\\(a\\)",
        "(?i)\\by/n(/a)?\\b",
        "(?i)Do you want to (allow|run|execute|proceed)",
        "(?i)Tool:.*\\n.*Allow",
        "(?i)(Press|Type)\\s+[yYnNaA]\\s+(to|for)",
    ]

    static func find(in app: CandidateApp, action: ResponseAction) -> PromptMatch? {
        guard let windows = axWindows(of: app.axApp) else {
            scanLog("     Terminal: no AX windows for \(app.bundleID)")
            return nil
        }
        scanLog("     Terminal: \(windows.count) window(s) for \(app.bundleID)")

        for (i, window) in windows.enumerated() {
            if let text = findTerminalText(in: window, depth: 0) {
                let tail = String(text.suffix(2000))

                // Skip windows that contain our own log output to avoid false matches
                if tail.contains("[AgentRemote]") {
                    scanLog("     Terminal window \(i): skipping (contains AgentRemote logs)")
                    continue
                }

                let preview = String(tail.suffix(200)).replacingOccurrences(of: "\n", with: "\\n")
                scanLog("     Terminal window \(i): found \(text.count) chars, tail preview: \"\(preview)\"")

                if let style = detectPromptStyle(tail) {
                    scanLog("     Terminal window \(i): ✅ prompt matched (\(style))")
                    let keys = keysFor(action: action, style: style, text: tail)
                    scanLog("     Keys: \(keys.map(\.label).joined(separator: " → "))")
                    return .terminalKeys(pid: app.pid, window: window, keys: keys)
                } else {
                    scanLog("     Terminal window \(i): no prompt pattern matched")
                }
            } else {
                scanLog("     Terminal window \(i): no text content found in AX tree")
            }
        }
        return nil
    }

    /// Walk the AX tree looking for a text area or large static text element
    /// (the terminal buffer). Returns the first sizable text content found.
    private static func findTerminalText(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 12 else { return nil }

        if let role = axString(element, kAXRoleAttribute) {
            if depth <= 3 {
                scanLog("       AX walk depth=\(depth) role=\(role)")
            }
            let isTextContainer = (role == kAXTextAreaRole as String)
                               || (role == kAXStaticTextRole as String)
                               || (role == "AXWebArea")  // Electron webview
            if isTextContainer {
                if let value = axString(element, kAXValueAttribute) {
                    scanLog("       Found text container (\(role)): \(value.count) chars")
                    if value.count > 20 {
                        return value
                    }
                } else {
                    scanLog("       Found text container (\(role)) but no AXValue")
                }
            }
        }

        guard let children = axChildren(element) else { return nil }
        for child in children {
            if let text = findTerminalText(in: child, depth: depth + 1) {
                return text
            }
        }
        return nil
    }

    /// Detect which prompt style is present in the text.
    private static func detectPromptStyle(_ text: String) -> PromptStyle? {
        for pattern in menuPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                scanLog("       Pattern matched (menu): \(pattern)")
                return .interactiveMenu
            }
        }
        for pattern in textPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                scanLog("       Pattern matched (text): \(pattern)")
                return .textPrompt
            }
        }
        scanLog("       No patterns matched against terminal text")
        return nil
    }

    /// Build the keystroke sequence for the given action and prompt style.
    private static func keysFor(action: ResponseAction, style: PromptStyle, text: String) -> [Key] {
        switch style {
        case .interactiveMenu:
            // Claude Code interactive menu: cursor starts on option 1 (Yes).
            // Navigate with Down arrows to the right option, then press Enter.
            //
            // Figure out which option is currently selected (❯ position)
            // and how many Down presses are needed to reach the target.
            let targetOption: Int
            switch action {
            case .allowOnce:  targetOption = 1  // "Yes"
            case .allowAlways: targetOption = 2 // "Yes, and don't ask again"
            case .deny:        targetOption = 3 // "No"
            }

            // Find which option the cursor is currently on
            let currentOption = currentMenuSelection(text) ?? 1
            let downs = targetOption - currentOption

            scanLog("       Menu: current=\(currentOption) target=\(targetOption) downs=\(downs)")

            var keys: [Key] = []
            if downs > 0 {
                keys += Array(repeating: Key.downArrow, count: downs)
            }
            // If downs < 0 we'd need Up arrows, but the cursor typically starts at 1
            // so this shouldn't happen in practice
            keys.append(.enter)
            return keys

        case .textPrompt:
            switch action {
            case .allowOnce:  return [.y]
            case .allowAlways: return [.a]
            case .deny:        return [.n]
            }
        }
    }

    /// Parse the interactive menu text to find which option the ❯ cursor is on.
    private static func currentMenuSelection(_ text: String) -> Int? {
        // Look for "❯ N." pattern
        guard let range = text.range(of: "❯\\s*(\\d+)\\.", options: .regularExpression) else {
            return nil
        }
        let match = text[range]
        // Extract the digit
        guard let digitRange = match.range(of: "\\d+", options: .regularExpression) else {
            return nil
        }
        return Int(match[digitRange])
    }
}

// MARK: - Activator

/// VS Code bundle IDs — not in the regular appRegistry because we can't
/// detect prompts via AX (xterm.js canvas). Instead we forward F-keys
/// to the VS Code extension which handles detection internally.
private let vscodeBundleIDs: Set<String> = [
    "com.microsoft.VSCode",
    "com.microsoft.VSCodeInsiders",
    "com.vscodium",
]

class Activator {

    func execute(_ match: PromptMatch) -> Bool {
        switch match {
        case .button(let element, _):
            return pressButton(element)
        case .terminalKeys(let pid, let window, let keys):
            return sendKeys(keys, to: pid, window: window)
        }
    }

    /// Forward the original F-key to VS Code so the Agent Remote extension
    /// can handle prompt detection in its terminal buffers.
    /// Briefly raises VS Code, injects the key, then restores z-order.
    func forwardToVSCode(action: ResponseAction) -> Bool {
        // Find a running VS Code instance
        guard let vscodeApp = NSWorkspace.shared.runningApplications.first(where: {
            guard let bid = $0.bundleIdentifier else { return false }
            return vscodeBundleIDs.contains(bid) && !$0.isTerminated
        }) else {
            scanLog("   VS Code: not running")
            return false
        }

        let pid = vscodeApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Find VS Code's frontmost window to raise
        guard let windows = axWindows(of: axApp), let window = windows.first else {
            scanLog("   VS Code: running but no AX windows")
            return false
        }

        // Map the action back to its F-key code
        let fKey: Key
        switch action {
        case .allowOnce:  fKey = Key(code: 105, label: "F13")
        case .allowAlways: fKey = Key(code: 106, label: "F16")
        case .deny:        fKey = Key(code: 64,  label: "F17")
        }

        scanLog("   VS Code: forwarding \(fKey.label) to pid \(pid)")
        return sendKeys([fKey], to: pid, window: window)
    }

    /// Press an AX button — works without bringing the window to front.
    private func pressButton(_ element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success {
            appLog.warning("AXPress failed: \(result.rawValue, privacy: .public)")
        }
        return result == .success
    }

    /// Send a sequence of keystrokes to a specific terminal window.
    /// Raises the target window just long enough to deliver keys,
    /// then restores the previously focused app and window.
    private func sendKeys(_ keys: [Key], to pid: pid_t, window: AXUIElement) -> Bool {
        // Remember the currently focused app and its focused window
        let previousApp = NSWorkspace.shared.frontmostApplication
        let previousPid = previousApp?.processIdentifier ?? 0
        let previousAxApp = AXUIElementCreateApplication(previousPid)
        var previousWindowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(previousAxApp, kAXFocusedWindowAttribute as CFString, &previousWindowRef)

        scanLog("       Saving focus: \(previousApp?.bundleIdentifier ?? "?") pid=\(previousPid)")

        // Raise the specific window that has the prompt so it becomes the key window
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let targetApp = NSRunningApplication(processIdentifier: pid)
        targetApp?.activate()

        // Let the window manager settle
        usleep(100_000) // 100ms

        for key in keys {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: false)
            else {
                scanLog("       Failed to create CGEvent for key \(key.label)")
                return false
            }

            down.postToPid(pid)
            up.postToPid(pid)

            // Small gap between keystrokes so the TUI can process each one
            usleep(50_000) // 50ms
        }

        // Restore the previously focused window and app
        usleep(50_000) // 50ms — let the last keystroke land
        if let prevWindow = previousWindowRef {
            AXUIElementPerformAction(prevWindow as! AXUIElement, kAXRaiseAction as CFString)
        }
        previousApp?.activate()
        scanLog("       Restored focus to \(previousApp?.bundleIdentifier ?? "?")")

        return true
    }
}

// MARK: - AX helper functions

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? String
}

func axChildren(_ element: AXUIElement) -> [AXUIElement]? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? [AXUIElement]
}

func axWindows(of app: AXUIElement) -> [AXUIElement]? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success else {
        return nil
    }
    return ref as? [AXUIElement]
}

// MARK: - AX tree dumper (for diagnostics)

enum AXTreeDumper {

    private static let dumpLog = Logger(subsystem: "com.tappister.agentremote", category: "axdump")

    /// Dump the AX tree rooted at `element` to the unified log.
    /// Invaluable for figuring out button labels and tree structure
    /// when adding support for a new app.
    static func dump(_ element: AXUIElement, label: String = "", maxDepth: Int = 5) {
        dumpLog.info("── \(label, privacy: .public) ──")
        walk(element, indent: 0, maxDepth: maxDepth)
    }

    private static func walk(_ element: AXUIElement, indent: Int, maxDepth: Int) {
        guard indent < maxDepth else { return }

        let pad = String(repeating: "  ", count: indent)
        let role  = axString(element, kAXRoleAttribute) ?? "?"
        let title = axString(element, kAXTitleAttribute) ?? ""
        let desc  = axString(element, kAXDescriptionAttribute) ?? ""
        let value = axString(element, kAXValueAttribute) ?? ""

        // Truncate long values (terminal buffers)
        let shortValue = value.count > 80
            ? String(value.prefix(40)) + "…" + String(value.suffix(40))
            : value

        var parts = ["\(pad)[\(role)]"]
        if !title.isEmpty { parts.append("title=\"\(title)\"") }
        if !desc.isEmpty  { parts.append("desc=\"\(desc)\"") }
        if !shortValue.isEmpty { parts.append("value=\"\(shortValue)\"") }

        let line = parts.joined(separator: " ")
        dumpLog.info("\(line, privacy: .public)")

        guard let children = axChildren(element) else { return }
        for child in children {
            walk(child, indent: indent + 1, maxDepth: maxDepth)
        }
    }
}