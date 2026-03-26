import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import { spawn } from 'child_process';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const HOOK_EVENTS = [
  'sessionStart',
  'sessionEnd',
  'beforeSubmitPrompt',
  'preToolUse',
  'postToolUse',
  'postToolUseFailure',
  'beforeShellExecution',
  'afterShellExecution',
  'beforeMCPExecution',
  'afterMCPExecution',
  'beforeReadFile',
  'afterFileEdit',
  'preCompact',
  'stop',
  'subagentStart',
  'subagentStop',
  'afterAgentResponse',
  'afterAgentThought',
];

const HOOKS_DIR     = path.join(os.homedir(), '.cursor', 'hooks');
const HOOKS_JSON    = path.join(os.homedir(), '.cursor', 'hooks.json');
const INSTALLED_PY  = path.join(HOOKS_DIR, 'coralogix_hook.py');
const INSTALLED_ENV = path.join(HOOKS_DIR, 'coralogix_hook.env');
const WRAPPER_SH    = path.join(HOOKS_DIR, 'coralogix_hook.sh');

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isInstalled(): boolean {
  return fs.existsSync(INSTALLED_PY) && fs.existsSync(WRAPPER_SH);
}

function buildEnvContent(cfg: vscode.WorkspaceConfiguration): string {
  const lines = [
    `CX_API_KEY=${cfg.get<string>('apiKey', '')}`,
    `CX_OTLP_ENDPOINT=${cfg.get<string>('otlpEndpoint', 'https://ingress.eu2.coralogix.com')}`,
    `CX_APPLICATION_NAME=${cfg.get<string>('applicationName', 'cursor')}`,
    `CX_SUBSYSTEM_NAME=${cfg.get<string>('subsystemName', 'ai-agent')}`,
    `CURSOR_MASK_PROMPTS=${cfg.get<boolean>('maskPrompts', false)}`,
    `CURSOR_OMIT_PRE_TOOL_USE_SPANS=${cfg.get<boolean>('omitPreToolUseSpans', false)}`,
    `CX_OTLP_DEBUG=${cfg.get<boolean>('debug', false)}`,
  ];
  return lines.join('\n') + '\n';
}

function mergeHooksJson(wrapperPath: string): void {
  let config: Record<string, unknown> = {};
  try {
    config = JSON.parse(fs.readFileSync(HOOKS_JSON, 'utf8'));
  } catch {
    config = {};
  }

  if (typeof config['version'] === 'undefined') config['version'] = 1;
  if (typeof config['hooks'] !== 'object' || config['hooks'] === null) {
    config['hooks'] = {};
  }

  const hooks = config['hooks'] as Record<string, unknown[]>;
  const entry = { command: wrapperPath, timeout: 10 };

  for (const event of HOOK_EVENTS) {
    const existing = (Array.isArray(hooks[event]) ? hooks[event] : []) as Record<string, unknown>[];
    const filtered = existing.filter((e) => e['command'] !== wrapperPath);
    filtered.push(entry);
    hooks[event] = filtered;
  }

  fs.mkdirSync(path.dirname(HOOKS_JSON), { recursive: true });
  fs.writeFileSync(HOOKS_JSON, JSON.stringify(config, null, 2) + '\n');
}

function removeFromHooksJson(): void {
  let config: Record<string, unknown> = {};
  try {
    config = JSON.parse(fs.readFileSync(HOOKS_JSON, 'utf8'));
  } catch {
    return;
  }

  const hooks = config['hooks'] as Record<string, unknown[]> | undefined;
  if (!hooks) return;

  for (const event of HOOK_EVENTS) {
    if (Array.isArray(hooks[event])) {
      hooks[event] = (hooks[event] as Record<string, unknown>[]).filter(
        (e) => e['command'] !== WRAPPER_SH
      );
    }
  }

  fs.writeFileSync(HOOKS_JSON, JSON.stringify(config, null, 2) + '\n');
}

function updateStatusBar(bar: vscode.StatusBarItem): void {
  const active = isInstalled();
  bar.text = active ? '$(pulse) CX Telemetry' : '$(circle-slash) CX Telemetry';
  bar.tooltip = active
    ? 'Coralogix hook active — click for status'
    : 'Coralogix hook not installed — click to set up';
  bar.backgroundColor = active
    ? undefined
    : new vscode.ThemeColor('statusBarItem.warningBackground');
}

function installPythonDeps(output: vscode.OutputChannel): Promise<void> {
  return new Promise((resolve, reject) => {
    const packages = ['opentelemetry-sdk', 'opentelemetry-exporter-otlp-proto-http'];

    function runPip(extraArgs: string[], onFail: () => void): void {
      const args = ['-m', 'pip', 'install', '--quiet', '--user', ...extraArgs, ...packages];
      const proc = spawn('python3', args);

      proc.stdout.on('data', (d: Buffer) => output.append(d.toString()));
      proc.stderr.on('data', (d: Buffer) => output.append(d.toString()));

      proc.on('close', (code) => {
        if (code === 0) {
          output.appendLine('Python dependencies installed.');
          resolve();
        } else {
          onFail();
        }
      });
    }

    // First attempt: --user
    // Fallback: --user --break-system-packages (Homebrew Python / PEP 668)
    runPip([], () =>
      runPip(['--break-system-packages'], () =>
        reject(new Error('pip install failed — see Output panel for details'))
      )
    );
  });
}

// ---------------------------------------------------------------------------
// Activate
// ---------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext): void {
  const output = vscode.window.createOutputChannel('Coralogix Telemetry');

  const statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusBar.command = 'cursorCoralogix.status';
  updateStatusBar(statusBar);
  statusBar.show();

  context.subscriptions.push(statusBar, output);

  // --- Setup command ---
  context.subscriptions.push(
    vscode.commands.registerCommand('cursorCoralogix.setup', async () => {
      const cfg = vscode.workspace.getConfiguration('cursorCoralogix');
      const apiKey   = cfg.get<string>('apiKey', '');
      const endpoint = cfg.get<string>('otlpEndpoint', '');

      if (!apiKey || !endpoint) {
        const action = await vscode.window.showErrorMessage(
          'Set cursorCoralogix.apiKey and cursorCoralogix.otlpEndpoint in Settings before running setup.',
          'Open Settings'
        );
        if (action === 'Open Settings') {
          vscode.commands.executeCommand('workbench.action.openSettings', 'cursorCoralogix');
        }
        return;
      }

      output.show(true);
      output.appendLine('--- Coralogix hook setup ---');

      try {
        // 1. Create hooks directory
        fs.mkdirSync(HOOKS_DIR, { recursive: true });

        // 2. Write env file (chmod 600 — credentials)
        fs.writeFileSync(INSTALLED_ENV, buildEnvContent(cfg), { mode: 0o600 });
        output.appendLine(`Env written:       ${INSTALLED_ENV}`);

        // 3. Copy hook.py from extension resources
        const srcHook = path.join(context.extensionPath, 'resources', 'hook.py');
        fs.copyFileSync(srcHook, INSTALLED_PY);
        output.appendLine(`Hook installed:    ${INSTALLED_PY}`);

        // 4. Write shell wrapper
        const wrapperContent = [
          '#!/usr/bin/env bash',
          '# Auto-generated by cursor-coralogix extension — do not edit manually',
          'set -a',
          `source "${INSTALLED_ENV}"`,
          'set +a',
          `exec python3 "${INSTALLED_PY}"`,
          '',
        ].join('\n');
        fs.writeFileSync(WRAPPER_SH, wrapperContent, { mode: 0o755 });
        output.appendLine(`Wrapper installed: ${WRAPPER_SH}`);

        // 5. Merge hooks.json
        mergeHooksJson(WRAPPER_SH);
        output.appendLine(`Hooks merged into: ${HOOKS_JSON}`);

        // 6. Install Python dependencies
        output.appendLine('Installing Python dependencies...');
        await installPythonDeps(output);

        updateStatusBar(statusBar);
        output.appendLine('\nDone! Restart Cursor to activate telemetry.');
        vscode.window.showInformationMessage(
          'Coralogix hooks installed. Restart Cursor to activate.',
          'Open Output'
        ).then((action) => {
          if (action === 'Open Output') output.show();
        });
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        output.appendLine(`\nSetup failed: ${msg}`);
        vscode.window.showErrorMessage(`Coralogix setup failed: ${msg}`);
      }
    })
  );

  // --- Uninstall command ---
  context.subscriptions.push(
    vscode.commands.registerCommand('cursorCoralogix.uninstall', async () => {
      const confirm = await vscode.window.showWarningMessage(
        'Remove Coralogix hooks from Cursor?',
        { modal: true },
        'Remove'
      );
      if (confirm !== 'Remove') return;

      try {
        removeFromHooksJson();
        for (const f of [INSTALLED_PY, INSTALLED_ENV, WRAPPER_SH]) {
          try { fs.unlinkSync(f); } catch { /* already gone */ }
        }
        updateStatusBar(statusBar);
        vscode.window.showInformationMessage(
          'Coralogix hooks removed. Restart Cursor to deactivate.'
        );
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        vscode.window.showErrorMessage(`Uninstall failed: ${msg}`);
      }
    })
  );

  // --- Status command ---
  context.subscriptions.push(
    vscode.commands.registerCommand('cursorCoralogix.status', () => {
      output.show();
      output.appendLine('\n--- Coralogix status ---');
      output.appendLine(`Hook active:  ${isInstalled()}`);
      output.appendLine(`Python hook:  ${INSTALLED_PY}  [${fs.existsSync(INSTALLED_PY) ? 'present' : 'missing'}]`);
      output.appendLine(`Env file:     ${INSTALLED_ENV}  [${fs.existsSync(INSTALLED_ENV) ? 'present' : 'missing'}]`);
      output.appendLine(`Wrapper:      ${WRAPPER_SH}  [${fs.existsSync(WRAPPER_SH) ? 'present' : 'missing'}]`);
      output.appendLine(`hooks.json:   ${HOOKS_JSON}  [${fs.existsSync(HOOKS_JSON) ? 'present' : 'missing'}]`);
    })
  );
}

export function deactivate(): void {}
