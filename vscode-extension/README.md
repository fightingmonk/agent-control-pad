# Agent Remote

One-tap approvals for AI agent prompts, right from your macro pad. Catches permission prompts in VS Code terminals and responds instantly — no mouse, no alt-tab, no breaking flow.

Part of the [Agent Control Pad](https://github.com/fightingmonk/agent-control-pad) project.

## What it does

When an AI agent (Claude Code, Codex CLI, etc.) asks for permission in a VS Code terminal, press a key on your macro pad to respond:

| Key | Command | Action |
|-----|---------|--------|
| F13 | Agent Remote: Allow Once | Sends `y` or selects "Yes" |
| F16 | Agent Remote: Allow Always | Sends `a` or selects "Yes, and don't ask again" |
| F17 | Agent Remote: Deny | Sends `n` or selects "No" |

The extension detects both interactive menus (arrow-key selection) and text prompts (y/n/a) automatically.

## Requirements

- **VS Code 1.93 or later** — uses the Shell Integration API
- **Terminal shell integration enabled** — this is on by default

## Usage

1. Open a terminal in VS Code and run an AI agent that produces permission prompts.
2. When a prompt appears, press a macro pad key or run the command from the command palette.
3. The status bar briefly shows `Agent Remote: Y`, `Agent Remote: A`, or `Agent Remote: N` to confirm.

Diagnostic output is available in the Output panel under **Agent Remote**.

## Remote environments (Codespaces, SSH, containers)

Shell integration may not activate automatically in remote terminals. If the extension isn't detecting prompts, add this to the remote machine's shell config (`~/.zshrc` or `~/.bashrc`):

```sh
[[ "$TERM_PROGRAM" == "vscode" ]] && . "$(code --locate-shell-integration-path zsh)"
```

Replace `zsh` with `bash` if using bash.

## Key bindings

F13, F16, and F17 are not present on standard keyboards, so there should be no conflicts. To remap, override in your `keybindings.json`:

- `agentRemote.allowOnce` — default `f13`
- `agentRemote.allowAlways` — default `f16`
- `agentRemote.deny` — default `f17`

## License

Public Domain (Unlicense)
