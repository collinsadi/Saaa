// Plays one editor window for Saaa's Swift tests (EditorBridgeTests): the
// real client and context builder against the real bridge on macOS.
// Usage: node out/test/driver.js <socket path>
import { BridgeClient } from '../src/client';
import { buildContext, type EditorView } from '../src/context';

const socketPath = process.argv[2];
const lines = ['const total = items.reduce((sum, item) => sum + item.value, 0);', 'console.log(total);'];
const view: EditorView = {
  file: 'src/total.ts',
  language: 'typescript',
  lineCount: lines.length,
  visible: [{ start: 0, end: lines.length - 1 }],
  cursorLine: 0,
  selection: '',
  problems: [{ line: 0, severity: 'error', message: "Property 'value' does not exist on type 'number'.", source: 'ts', code: '2339' }],
  lineAt: (index) => lines[index],
};

let wasConnected = false;
const client = new BridgeClient({
  socketPath,
  hello: () => ({ app: 'Driver Editor', scheme: 'vscode', version: 'test', extension: 'test', workspace: 'e2e', focused: true }),
  context: () => buildContext(view, null),
  retryMs: { first: 50, max: 200 },
  onStateChange: (connected) => {
    if (connected) wasConnected = true;
    else if (wasConnected) process.exit(0);
  },
});
client.start();
// Never outlive the test.
setTimeout(() => process.exit(2), 20_000);
