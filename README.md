# Agent Control Pad

Stop switching windows to approve your AI agent's actions. Agent Control Pad is a tiny Bluetooth macro pad that lets you allow, always-allow, or deny any agent permission prompt without leaving your current task. 

Works with Claude Code, Claude Desktop, Cursor, Codex CLI, VS Code, and every major macOS terminal.

## How it works

```
┌─────────────┐   F13/F16/F17    ┌──────────────────┐
│  Macro Pad  │ ──── BLE ──────► │     macOS        │
│  (ZMK)      │                  │                  │
└─────────────┘                  │  ┌─────────────┐ │
                                 │  │ AgentRemote │─┼──► Claude Desktop, Cursor (AX button press)
                                 │  │ (menu bar)  │─┼──► Terminal, iTerm, Ghostty, etc. (keystroke)
                                 │  │             │─┼──► VS Code (forwards F-key to extension)
                                 │  └─────────────┘ │
                                 │                  │
                                 │  ┌─────────────┐ │
                                 │  │ VS Code Ext │─┼──► VS Code integrated terminal (shell integration API)
                                 │  └─────────────┘ │
                                 └──────────────────┘
```

| Key | Action |
|-----|--------|
| F13 | Allow Once (Yes) |
| F16 | Allow Always (Yes, don't ask again) |
| F17 | Deny (No) |

The macro pad sends F13/F16/F17 over Bluetooth or USB. **AgentRemote** (a macOS menu bar app) catches those keys globally and responds to prompts in GUI apps via the Accessibility API and in terminal emulators via buffer reading and keystrokes. **VS Code** gets special treatment — its xterm.js canvas isn't readable via AX, so AgentRemote forwards the F-key to VS Code where a companion extension handles prompt detection.

## Quick start

### AgentRemote (macOS menu bar app)

Build and run:

```sh
cd AgentRemote
./bundle.sh
open AgentRemote.app
```

Grant **Accessibility** and **Input Monitoring** permissions in System Settings > Privacy & Security.

A **✦** icon appears in the menu bar. Press a macro pad key (or F13/F16/F17 on any keyboard) while an agent prompt is visible — the icon briefly flashes when it activates the agent:

- **Y** / **A** / **N** — action sent
- **—** — agent window found, but no permission prompt was detected
- **○** — no known agent windows are visible

**Allow Always requires a double-tap by default** — press F16 twice within 2 seconds to confirm. This prevents accidentally granting blanket permission with a single mispress. You can toggle this off in the AgentRemote menu bar icon under "Require Double-Tap for Allow Always".

See [AgentRemote/README.md](AgentRemote/README.md) for architecture details, diagnostics, and how to add support for new apps.

### VS Code Extension

Build and install:

```sh
cd vscode-extension
npm install
npm run compile
npm run package
# Install from command line
code --install-extension agent-remote-*.vsix
# or in VS Code command palette use 
#   View > Command Palette > Extensions: Install from VSIX...
# and browse to the agent-remote-*.vsix file you created
```

Requires **VS Code 1.93+** with terminal shell integration enabled (the default).

The extension listens for F13/F16/F17 inside VS Code, detects permission prompts in the terminal buffer, and sends the appropriate response. Diagnostic output is in the Output panel under **Agent Remote**.

#### Remote environments (Codespaces, SSH, containers)

Shell integration may not activate automatically in remote terminals. If the extension isn't detecting prompts, add this to the remote machine's shell config (e.g. `~/.zshrc` or `~/.bashrc`):

```sh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
```

Replace `zsh` with `bash` if using bash.

### Hardware

See [macropad/README.md](macropad/README.md) for the full build guide, bill of materials, wiring scheme, case design, and firmware flashing instructions.

If you have a macro pad and don't want to build your own, just configure it to send these keys:

* `Approve action` - F13
* `Approve always` - F16
* `Deny` - F17

## Resetting Bluetooth

If the macro pad won't connect (e.g. after pairing with a different computer), you can clear all stored Bluetooth bonds directly from the pad:

1. Hold **F13 + F17** (the outer two keys) simultaneously for **1 second**.
2. The pad clears all bond data and starts advertising as a new device.
3. On your Mac, go to System Settings > Bluetooth and connect to it.

To forget a stale pairing on the Mac side: System Settings > Bluetooth, click the **(i)** next to the device, then **Forget This Device**.

## Changing the key bindings

F13, F16, and F17 were chosen because they exist in the USB HID spec but aren't on standard keyboards, so they won't conflict with anything. F14 and F15 are skipped because macOS uses them for brightness controls. If you want to use different keys, you need to change all three layers:

1. **Firmware** — edit `macropad/config/macropad.keymap` to change which key codes the macro pad sends, then rebuild and flash the firmware (see [macropad/README.md](macropad/README.md)).

2. **AgentRemote** — edit the `ResponseAction(keyCode:)` switch in `AgentRemote/Sources/AgentRemote/App.swift` to match your new key codes, and update the corresponding `forwardToVSCode` key codes in `Scanner.swift`.

3. **VS Code Extension** — edit the `keybindings` array in `vscode-extension/package.json` to match your new keys, then rebuild and reinstall the extension.
