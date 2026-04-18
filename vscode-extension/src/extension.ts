import * as vscode from 'vscode';

// ── ANSI / control character stripping ──────────────────────────────────────

function stripAnsi(text: string): string {
    return text
        .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')     // CSI sequences
        .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '') // OSC sequences
        .replace(/\x1b[^[\]]/g, '')                   // Other escape sequences
        .replace(/\r/g, '');                           // Carriage returns
}

// ── Prompt detection (ported from AgentRemote/Scanner.swift) ────────────────

type PromptStyle = 'interactiveMenu' | 'textPrompt';

// Claude Code interactive menu: "❯ 1. Yes / 2. Yes, and don't ask again / 3. No"
const MENU_PATTERNS: RegExp[] = [
    /Do you want to proceed\?[\s\S]*?\d+\.\s*(Yes|No)/,
    /❯\s*\d+\.\s*(Yes|No)/,
];

// Classic y/n/a text prompts
const TEXT_PATTERNS: RegExp[] = [
    /\b(allow|approve|permit|run)\b.*\?/i,
    /\[(y|Y)\/(n|N)\/(a|A)\]/,
    /\(y\).*\(n\).*\(a\)/i,
    /\by\/n(\/a)?\b/i,
    /Do you want to (allow|run|execute|proceed)/i,
    /Tool:[\s\S]*?Allow/i,
    /(Press|Type)\s+[yYnNaA]\s+(to|for)/i,
];

function detectPrompt(text: string): PromptStyle | null {
    for (const p of MENU_PATTERNS) { if (p.test(text)) { return 'interactiveMenu'; } }
    for (const p of TEXT_PATTERNS) { if (p.test(text)) { return 'textPrompt'; } }
    return null;
}

// Parse which option the ❯ cursor is currently on (defaults to 1)
function currentMenuSelection(text: string): number {
    const m = text.match(/❯\s*(\d+)\./);
    return m ? parseInt(m[1], 10) : 1;
}

// ── Response building ───────────────────────────────────────────────────────

type Action = 'allowOnce' | 'allowAlways' | 'deny';

function buildKeystrokes(action: Action, style: PromptStyle, text: string): string[] {
    if (style === 'interactiveMenu') {
        // Interactive menu: navigate with arrow keys then press enter.
        // Option mapping: 1 = Yes, 2 = Yes and don't ask again, 3 = No
        // Each keystroke must be sent individually with a delay so the
        // raw-mode menu reader processes them one at a time.
        const target = action === 'allowOnce' ? 1 : action === 'allowAlways' ? 2 : 3;
        const current = currentMenuSelection(text);
        const moves = target - current;

        const keys: string[] = [];
        const arrow = moves > 0 ? '\x1b[B' : '\x1b[A';
        for (let i = 0; i < Math.abs(moves); i++) {
            keys.push(arrow);
        }
        keys.push('\r'); // Enter
        return keys;
    }

    // Text prompt: single character response
    switch (action) {
        case 'allowOnce':  return ['y'];
        case 'allowAlways': return ['a'];
        case 'deny':        return ['n'];
    }
}

// ── Per-terminal output buffering ───────────────────────────────────────────

const BUFFER_MAX = 4000;
const buffers = new Map<vscode.Terminal, string>();

function appendBuffer(terminal: vscode.Terminal, rawData: string): void {
    const prev = buffers.get(terminal) ?? '';
    const updated = (prev + stripAnsi(rawData)).slice(-BUFFER_MAX);
    buffers.set(terminal, updated);
}

// ── Action handler ──────────────────────────────────────────────────────────

const KEYSTROKE_DELAY_MS = 50;

function delay(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function handleAction(action: Action, log: vscode.OutputChannel): Promise<void> {
    // Check the active terminal first, then scan all others
    const active = vscode.window.activeTerminal;
    const ordered: [vscode.Terminal, string][] = [];

    if (active) {
        const buf = buffers.get(active);
        if (buf) { ordered.push([active, buf]); }
    }
    for (const [terminal, buffer] of buffers) {
        if (terminal !== active) {
            ordered.push([terminal, buffer]);
        }
    }

    log.appendLine(`[debug] action=${action} terminals_with_buffers=${ordered.length} total_buffers=${buffers.size}`);

    for (const [terminal, buffer] of ordered) {
        // Skip terminals that contain our own diagnostic logs
        if (buffer.includes('[AgentRemote]')) {
            log.appendLine(`[debug] skipping "${terminal.name}" (contains [AgentRemote])`);
            continue;
        }

        const tail = buffer.slice(-2000);
        log.appendLine(`[debug] "${terminal.name}" buffer=${buffer.length} chars, tail=${tail.length} chars`);
        log.appendLine(`[debug] tail (last 500): ${tail.slice(-500)}`);

        const style = detectPrompt(tail);
        if (style) {
            const keys = buildKeystrokes(action, style, tail);

            // Clear buffer immediately to prevent re-triggering on stale prompt text
            buffers.set(terminal, '');

            // Send each keystroke individually with a delay so raw-mode
            // menu readers (e.g. inquirer) process them one at a time.
            for (const key of keys) {
                terminal.sendText(key, false);
                await delay(KEYSTROKE_DELAY_MS);
            }

            const icon = action === 'allowOnce' ? 'Y' : action === 'allowAlways' ? 'A' : 'N';
            vscode.window.setStatusBarMessage(`Agent Remote: ${icon}`, 1500);
            log.appendLine(`${icon} → ${terminal.name} (${style})`);
            return;
        } else {
            log.appendLine(`[debug] no prompt pattern matched in "${terminal.name}"`);
        }
    }

    vscode.window.setStatusBarMessage('Agent Remote: \u2014', 1500);
    log.appendLine('\u2014 no prompt found');
}

// ── Extension lifecycle ─────────────────────────────────────────────────────

export function activate(context: vscode.ExtensionContext): void {
    const log = vscode.window.createOutputChannel('Agent Remote');

    // Buffer terminal output via the Shell Integration API (stable since 1.93).
    // This fires when any command starts executing in a terminal with shell
    // integration active. We read the command's output stream and buffer it
    // for prompt detection.
    context.subscriptions.push(
        vscode.window.onDidStartTerminalShellExecution(async (e) => {
            try {
                for await (const data of e.execution.read()) {
                    appendBuffer(e.terminal, data);
                }
            } catch {
                // Execution ended or terminal was closed — expected
            }
        })
    );

    // Clean up buffers when terminals close
    context.subscriptions.push(
        vscode.window.onDidCloseTerminal((terminal) => {
            buffers.delete(terminal);
        })
    );

    // Register commands bound to F13 / F16 / F17
    context.subscriptions.push(
        vscode.commands.registerCommand('agentRemote.allowOnce', () => handleAction('allowOnce', log)),
        vscode.commands.registerCommand('agentRemote.allowAlways', () => handleAction('allowAlways', log)),
        vscode.commands.registerCommand('agentRemote.deny', () => handleAction('deny', log)),
    );

    log.appendLine('Agent Remote activated \u2014 listening for terminal prompts');
}

export function deactivate(): void {
    buffers.clear();
}
