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

const IS_WIN = process.platform === 'win32';

const HOOKS_DIR     = path.join(os.homedir(), '.cursor', 'hooks');
const HOOKS_JSON    = path.join(os.homedir(), '.cursor', 'hooks.json');
const INSTALLED_PY  = path.join(HOOKS_DIR, 'coralogix_hook.py');
const INSTALLED_ENV = path.join(HOOKS_DIR, 'coralogix_hook.env');
const WRAPPER_SH    = path.join(HOOKS_DIR, 'coralogix_hook.sh');
const WRAPPER_CMD   = path.join(HOOKS_DIR, 'coralogix_hook.cmd');
const WRAPPER_PS1   = path.join(HOOKS_DIR, 'coralogix_hook.ps1');

// hooks.json's registered command — used for install detection, merge, and removal.
const WRAPPER = IS_WIN ? WRAPPER_CMD : WRAPPER_SH;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function isInstalled(): boolean {
  return fs.existsSync(INSTALLED_PY) && fs.existsSync(WRAPPER);
}

function buildEnvContent(apiKey: string, cfg: vscode.WorkspaceConfiguration): string {
  const lines = [
    `CX_API_KEY=${apiKey}`,
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
        (e) => e['command'] !== WRAPPER
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

    function runPip(cmd: string, prefixArgs: string[], extraArgs: string[], onFail: () => void): void {
      const args = [...prefixArgs, '-m', 'pip', 'install', '--quiet', '--user', ...extraArgs, ...packages];
      const proc = spawn(cmd, args);
      let settled = false;

      proc.stdout.on('data', (d: Buffer) => output.append(d.toString()));
      proc.stderr.on('data', (d: Buffer) => output.append(d.toString()));

      // spawn emits ENOENT via 'error'; fall through to the next interpreter.
      proc.on('error', () => {
        if (settled) return;
        settled = true;
        onFail();
      });

      proc.on('close', (code) => {
        if (settled) return;
        settled = true;
        if (code === 0) {
          output.appendLine('Python dependencies installed.');
          resolve();
        } else {
          onFail();
        }
      });
    }

    if (IS_WIN) {
      // Try python, then py -3, then python3; the first one that spawns is reused.
      const candidates: Array<{ cmd: string; prefixArgs: string[] }> = [
        { cmd: 'python', prefixArgs: [] },
        { cmd: 'py', prefixArgs: ['-3'] },
        { cmd: 'python3', prefixArgs: [] },
      ];

      const tryNext = (i: number): void => {
        if (i >= candidates.length) {
          reject(new Error('No Python interpreter found (tried python, py -3, python3)'));
          return;
        }
        const { cmd, prefixArgs } = candidates[i];
        runPip(cmd, prefixArgs, [], () => tryNext(i + 1));
      };

      tryNext(0);
    } else {
      // First attempt: --user
      // Fallback: --user --break-system-packages (Homebrew Python / PEP 668)
      runPip('python3', [], [], () =>
        runPip('python3', [], ['--break-system-packages'], () =>
          reject(new Error('pip install failed — see Output panel for details'))
        )
      );
    }
  });
}

function restrictWindowsAcl(filePath: string, output: vscode.OutputChannel): Promise<void> {
  // Node's `mode: 0o600` is a no-op on NTFS; the file otherwise inherits folder ACLs.
  return new Promise((resolve) => {
    const psLiteral = filePath.replace(/'/g, "''");
    const script = [
      `$acl = Get-Acl -LiteralPath '${psLiteral}'`,
      '$acl.SetAccessRuleProtection($true, $false)',
      'foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }',
      '$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name',
      "$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $who, 'FullControl', 'None', 'None', 'Allow'))",
      `Set-Acl -LiteralPath '${psLiteral}' -AclObject $acl`,
    ].join('; ');

    let settled = false;
    const finish = (): void => {
      if (settled) return;
      settled = true;
      resolve();
    };
    const warn = (): void => {
      output.appendLine(`Warning: could not restrict permissions on ${filePath} — it contains your API key.`);
    };

    try {
      const proc = spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
      proc.on('error', () => {
        warn();
        finish();
      });
      proc.on('close', (code) => {
        if (code !== 0) warn();
        finish();
      });
    } catch {
      warn();
      finish();
    }
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

  const SECRET_KEY = 'cursorCoralogix.apiKey';

  // --- Setup command ---
  context.subscriptions.push(
    vscode.commands.registerCommand('cursorCoralogix.setup', async () => {
      const cfg = vscode.workspace.getConfiguration('cursorCoralogix');
      const endpoint = cfg.get<string>('otlpEndpoint', '');

      // Retrieve stored key or prompt the user (masked input)
      let apiKey = await context.secrets.get(SECRET_KEY) ?? '';
      if (!apiKey) {
        const input = await vscode.window.showInputBox({
          title: 'Coralogix API Key',
          prompt: 'Paste your Send-Your-Data API key (Settings → API Keys in your tenant)',
          password: true,
          ignoreFocusOut: true,
        });
        if (!input) return;
        await context.secrets.store(SECRET_KEY, input);
        apiKey = input;
      }

      if (!endpoint) {
        const action = await vscode.window.showErrorMessage(
          'Set cursorCoralogix.otlpEndpoint in Settings before running setup.',
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
        fs.writeFileSync(INSTALLED_ENV, buildEnvContent(apiKey, cfg), { mode: 0o600 });
        output.appendLine(`Env written:       ${INSTALLED_ENV}`);
        if (IS_WIN) {
          await restrictWindowsAcl(INSTALLED_ENV, output);
        }

        // 3. Copy hook.py from extension resources
        const srcHook = path.join(context.extensionPath, 'resources', 'hook.py');
        fs.copyFileSync(srcHook, INSTALLED_PY);
        output.appendLine(`Hook installed:    ${INSTALLED_PY}`);

        // 4. Write runtime wrapper
        if (IS_WIN) {
          const ps1Content = [
            '# Auto-generated by cursor-coralogix extension - do not edit manually',
            "$ErrorActionPreference = 'SilentlyContinue'",
            'try {',
            '    $envFile = Join-Path $PSScriptRoot "coralogix_hook.env"',
            // Allowlist: the env file only ever holds these; refusing anything else
            // closes off a PYTHONPATH-style injection surface if it's tampered with.
            "    $allowedKeys = @('CX_API_KEY', 'CX_OTLP_ENDPOINT', 'CX_APPLICATION_NAME', 'CX_SUBSYSTEM_NAME', 'CURSOR_MASK_PROMPTS', 'CURSOR_OMIT_PRE_TOOL_USE_SPANS', 'CX_OTLP_DEBUG')",
            '    if (Test-Path $envFile) {',
            '        Get-Content $envFile | ForEach-Object {',
            '            $line = $_.Trim()',
            "            if ($line -eq '' -or $line.StartsWith('#')) { return }",
            "            $idx = $line.IndexOf('=')",
            '            if ($idx -lt 0) { return }',
            '            $name = $line.Substring(0, $idx).Trim()',
            '            $value = $line.Substring($idx + 1).Trim()',
            '            if ($allowedKeys -notcontains $name) { return }',
            "            [Environment]::SetEnvironmentVariable($name, $value, 'Process')",
            '        }',
            '    }',
            '',
            '    $pythonCmd = $null',
            '    $pythonArgs = @()',
            '    foreach ($candidate in @(',
            "        @{ Cmd = 'python'; Args = @() },",
            "        @{ Cmd = 'py'; Args = @('-3') },",
            "        @{ Cmd = 'python3'; Args = @() }",
            '    )) {',
            '        if (Get-Command $candidate.Cmd -ErrorAction SilentlyContinue) {',
            '            $pythonCmd = $candidate.Cmd',
            '            $pythonArgs = $candidate.Args',
            '            break',
            '        }',
            '    }',
            '    if (-not $pythonCmd) { exit 0 }',
            '',
            '    & $pythonCmd @pythonArgs "$PSScriptRoot\\coralogix_hook.py"',
            '    exit $LASTEXITCODE',
            '} catch {',
            '    exit 0',
            '}',
            '',
          ].join('\n');
          fs.writeFileSync(WRAPPER_PS1, ps1Content);
          output.appendLine(`Wrapper installed: ${WRAPPER_PS1}`);

          const cmdContent = [
            '@echo off',
            'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0coralogix_hook.ps1" %*',
            '',
          ].join('\n');
          fs.writeFileSync(WRAPPER_CMD, cmdContent);
          output.appendLine(`Wrapper installed: ${WRAPPER_CMD}`);
        } else {
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
        }

        // 5. Merge hooks.json
        mergeHooksJson(WRAPPER);
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

  // --- Set API Key command ---
  context.subscriptions.push(
    vscode.commands.registerCommand('cursorCoralogix.setApiKey', async () => {
      const input = await vscode.window.showInputBox({
        title: 'Coralogix API Key',
        prompt: 'Paste your Send-Your-Data API key (Settings → API Keys in your tenant)',
        password: true,
        ignoreFocusOut: true,
      });
      if (!input) return;
      await context.secrets.store(SECRET_KEY, input);
      vscode.window.showInformationMessage('Coralogix API key saved. Run setup to apply.');
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
        const filesToRemove = IS_WIN
          ? [INSTALLED_PY, INSTALLED_ENV, WRAPPER_CMD, WRAPPER_PS1]
          : [INSTALLED_PY, INSTALLED_ENV, WRAPPER_SH];
        for (const f of filesToRemove) {
          try { fs.unlinkSync(f); } catch { /* already gone */ }
        }
        await context.secrets.delete(SECRET_KEY);
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
      output.appendLine(`Wrapper:      ${WRAPPER}  [${fs.existsSync(WRAPPER) ? 'present' : 'missing'}]`);
      if (IS_WIN) {
        output.appendLine(`  PS1 script: ${WRAPPER_PS1}  [${fs.existsSync(WRAPPER_PS1) ? 'present' : 'missing'}]`);
      }
      output.appendLine(`hooks.json:   ${HOOKS_JSON}  [${fs.existsSync(HOOKS_JSON) ? 'present' : 'missing'}]`);
    })
  );
}

export function deactivate(): void {}
