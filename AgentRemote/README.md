# AgentRemote

macOS menu bar app that catches F13/F16/F17 key events globally and sends responses to AI agent permission prompts across GUI apps and terminal emulators.

For build/install instructions and an overview of the full system, see the [top-level README](../README.md).

## How it works

1. A CGEvent tap catches F13/F16/F17 globally.
2. The scanner walks visible windows front-to-back.
3. For each known agent-like application window, it checks for a pending permission prompt:
   - **GUI apps** (Claude Desktop, Cursor): walks the Accessibility tree looking for buttons labeled "Allow", "Deny", etc.
   - **Terminal apps** (Terminal, iTerm, Ghostty, Kitty, Warp, Alacritty): reads the terminal buffer text and matches against `y/n/a`-style prompt patterns, then sends the matching keystroke.
4. First match wins — the response is sent and the menu bar icon briefly flashes.
5. If no prompt is found in any window, and VS Code is running, the F-key is forwarded to VS Code as a fallback. The companion extension handles prompt detection there since VS Code's xterm.js canvas isn't readable via AX (see [vscode-extension](../vscode-extension/)).

## Supported apps

| App | Method |
|-----|--------|
| Claude Desktop | AX tree button press |
| Cursor | AX tree button press |
| Terminal.app | Buffer read + keystroke |
| iTerm2 | Buffer read + keystroke |
| Ghostty | Buffer read + keystroke |
| Kitty | Buffer read + keystroke |
| Warp | Buffer read + keystroke |
| Alacritty | Buffer read + keystroke |
| Hyper | Buffer read + keystroke |
| VS Code / VS Code Insiders | F-key forwarded to extension |

## Setup

### Permissions

The app requires two macOS permissions (System Settings > Privacy & Security):

1. **Accessibility** — read window contents and press buttons via the AX API.
2. **Input Monitoring** — CGEvent tap that catches F13/F16/F17.

When running from source with `swift run`, grant Input Monitoring to your terminal app instead of AgentRemote.

### Launch at login (optional)

Create `~/Library/LaunchAgents/com.agentremote.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agentremote</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/AgentRemote</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

Then:
```sh
launchctl load ~/Library/LaunchAgents/com.agentremote.plist
```

## Diagnostics

The menu bar icon has two diagnostic tools:

- **Diagnostic Scan** — scans all visible windows and logs which known apps were found and whether any prompts were detected.
- **Dump Frontmost AX Tree** — prints the Accessibility tree of the focused app. Use this when adding support for a new app.

### Reading logs

```sh
log stream --predicate 'eventMessage CONTAINS "AgentRemote"' --style compact
```

## Adding support for a new app

1. Open the app and trigger a permission prompt.
2. Click **Dump Frontmost AX Tree** in the Agent Remote menu bar icon.
3. Check the logs for the tree structure — look for `AXButton` nodes and their `title` values.
4. Add the app's bundle ID to `appRegistry` in `Scanner.swift`:

```swift
let appRegistry: [String: AppCategory] = [
    // ...existing entries...
    "com.example.newagent": .gui,  // or .terminal
]
```

5. If the button labels use non-standard wording, update the `matches(label:action:)` function in `GUIDetector`.

To find an app's bundle ID:

```sh
osascript -e 'id of app "AppName"'
# or
mdls -name kMDItemCFBundleIdentifier /Applications/AppName.app
```

## Architecture

```
main.swift          → boots NSApplication
App.swift           → AppDelegate: menu bar, key monitor, orchestration
Scanner.swift       → WindowScanner, GUIDetector, TerminalDetector, Activator
```

The scan runs on a dedicated serial queue (`userInteractive` QoS) so the main thread stays responsive. GUI button presses via `AXPress` don't require focus changes. Terminal keystrokes briefly activate the target app, send the key, then restore the previous app (~150ms round trip).

## Known limitations

- **Terminal prompt detection** relies on regex matching against the visible text buffer. If an agent tool uses a pure ncurses TUI with no text-selectable prompt, the text may not be accessible. The diagnostic dump tool will reveal whether the content is readable.

- **Focus flicker on terminal activation**: when sending keystrokes to a terminal, the target app is briefly brought to front and then restored to it's original z order. This can cause a visible flash on screen.
