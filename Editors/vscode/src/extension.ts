import * as os from 'node:os';
import * as path from 'node:path';
import * as vscode from 'vscode';
import { BridgeClient } from './client';
import { buildContext, type EditorView } from './context';
import { TerminalTracker } from './terminal';

/** Saaa listens here, in its own folder on the Mac. */
export function socketPath(): string {
  return path.join(os.homedir(), 'Library', 'Application Support', 'Saaa', 'editor.sock');
}

export function activate(context: vscode.ExtensionContext): void {
  // Saaa is a Mac app; elsewhere there is nothing to connect to.
  if (process.platform !== 'darwin') return;

  const setting = (key: 'enabled' | 'shareTerminal'): boolean =>
    vscode.workspace.getConfiguration('saaa').get<boolean>(key, true);
  const version = String(context.extension.packageJSON.version ?? '0.0.0');
  const tracker = new TerminalTracker();
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 0);
  status.command = 'saaa.toggle';
  status.name = 'Saaa';

  const render = (): void => {
    if (setting('enabled') && client.isConnected) {
      status.text = '$(eye) Saaa';
      status.tooltip = 'Saaa reads this editor only when you press Look or Watch is on. Click to stop it.';
      status.show();
    } else {
      status.hide();
    }
  };

  const client = new BridgeClient({
    socketPath: socketPath(),
    hello: () => ({
      app: vscode.env.appName,
      scheme: vscode.env.uriScheme,
      version: vscode.version,
      extension: version,
      workspace: vscode.workspace.name ?? null,
      focused: vscode.window.state.focused,
    }),
    context: () => buildContext(activeView(), setting('shareTerminal') ? tracker.lastFailure() : null),
    onStateChange: render,
  });

  const apply = (): void => {
    if (setting('enabled')) {
      client.start();
    } else {
      client.stop();
      tracker.clear();
    }
    if (!setting('shareTerminal')) tracker.clear();
    render();
  };

  context.subscriptions.push(
    status,
    { dispose: () => client.stop() },
    vscode.window.onDidChangeWindowState((state) => client.sendFocus(state.focused)),
    vscode.window.onDidStartTerminalShellExecution((event) => {
      if (setting('enabled') && setting('shareTerminal')) {
        tracker.started(event.execution, event.terminal, event.execution.read());
      }
    }),
    vscode.window.onDidEndTerminalShellExecution((event) => {
      void tracker.ended(event.execution, event.terminal, event.execution.commandLine.value, event.exitCode);
    }),
    vscode.window.onDidCloseTerminal((terminal) => tracker.closed(terminal)),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration('saaa')) apply();
    }),
    vscode.commands.registerCommand('saaa.toggle', async () => {
      const next = !setting('enabled');
      await vscode.workspace.getConfiguration('saaa').update('enabled', next, vscode.ConfigurationTarget.Global);
      void vscode.window.showInformationMessage(
        next ? 'Saaa can read this editor when you press Look or Watch is on.' : 'Saaa will read the screen instead of this editor.',
      );
    }),
  );
  apply();
}

export function deactivate(): void {
  // Subscriptions close the connection.
}

/** The active text editor as plain data, or null when focus is on something else (a preview, a webview). */
function activeView(): EditorView | null {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return null;
  const document = editor.document;
  const problems: EditorView['problems'] = [];
  for (const diagnostic of vscode.languages.getDiagnostics(document.uri)) {
    if (diagnostic.severity !== vscode.DiagnosticSeverity.Error && diagnostic.severity !== vscode.DiagnosticSeverity.Warning) {
      continue;
    }
    problems.push({
      line: diagnostic.range.start.line,
      severity: diagnostic.severity === vscode.DiagnosticSeverity.Error ? 'error' : 'warning',
      message: diagnostic.message,
      source: diagnostic.source,
      code: codeText(diagnostic.code),
    });
  }
  return {
    file: fileLabel(document),
    language: document.languageId,
    lineCount: document.lineCount,
    visible: editor.visibleRanges.map((range) => ({ start: range.start.line, end: range.end.line })),
    cursorLine: editor.selection.active.line,
    selection: editor.selection.isEmpty ? '' : document.getText(editor.selection),
    problems,
    lineAt: (index) => document.lineAt(index).text,
  };
}

function codeText(code: vscode.Diagnostic['code']): string | undefined {
  if (code === undefined) return undefined;
  return typeof code === 'object' ? String(code.value) : String(code);
}

/** A workspace-relative path, or the file's last two path parts: never the home folder. */
function fileLabel(document: vscode.TextDocument): string {
  if (document.isUntitled) return 'Untitled';
  const relative = vscode.workspace.asRelativePath(document.uri, false);
  if (!path.isAbsolute(relative)) return relative;
  return relative.split(path.sep).filter(Boolean).slice(-2).join('/');
}
