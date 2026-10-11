import assert from 'node:assert/strict';
import { once } from 'node:events';
import * as fs from 'node:fs';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';
import { test } from 'node:test';
import { BridgeClient, socketLooksRight } from '../src/client';
import { LineReader } from '../src/lines';
import type { EditorContext } from '../src/protocol';

const sample: EditorContext = {
  file: 'a.py',
  language: 'python',
  lineCount: 1,
  cursorLine: 1,
  visible: [{ startLine: 1, text: 'print(x)' }],
  snippets: [],
  selection: null,
  problems: [{ line: 1, severity: 'error', message: '"x" is not defined' }],
  terminal: null,
};

/** A stand-in for Saaa: accepts one connection at a time and collects messages. */
class FakeSaaa {
  readonly server: net.Server;
  readonly messages: Array<Record<string, unknown>> = [];
  socket: net.Socket | null = null;
  private waiters: Array<() => void> = [];

  constructor(readonly socketPath: string) {
    this.server = net.createServer((socket) => {
      this.socket = socket;
      socket.setEncoding('utf8');
      const reader = new LineReader();
      socket.on('data', (chunk: string) => {
        for (const line of reader.push(chunk)) this.messages.push(JSON.parse(line));
        this.waiters.splice(0).forEach((wake) => wake());
      });
    });
  }

  async listen(): Promise<void> {
    this.server.listen(this.socketPath);
    await once(this.server, 'listening');
  }

  async next(type: string, after = 0): Promise<Record<string, unknown>> {
    for (;;) {
      const found = this.messages.slice(after).find((message) => message.type === type);
      if (found) return found;
      await new Promise<void>((resolve) => this.waiters.push(resolve));
    }
  }

  async close(): Promise<void> {
    this.socket?.destroy();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}

function temporarySocket(): string {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'saaa-')), 'editor.sock');
}

function makeClient(socketPath: string, context: () => EditorContext | null = () => sample): BridgeClient {
  return new BridgeClient({
    socketPath,
    hello: () => ({ app: 'Visual Studio Code', scheme: 'vscode', version: '1.93.0', extension: '0.1.0', workspace: 'saaa', focused: true }),
    context,
    retryMs: { first: 20, max: 40 },
  });
}

test('says hello, then answers a request with the context', async () => {
  const saaa = new FakeSaaa(temporarySocket());
  await saaa.listen();
  const client = makeClient(saaa.socketPath);
  client.start();
  try {
    const hello = await saaa.next('hello');
    assert.equal(hello.protocol, 1);
    assert.equal(hello.app, 'Visual Studio Code');
    assert.equal(hello.workspace, 'saaa');
    saaa.socket!.write(JSON.stringify({ type: 'context', id: 7 }) + '\n');
    const reply = await saaa.next('context');
    assert.deepEqual(reply, { type: 'context', id: 7, context: sample });
  } finally {
    client.stop();
    await saaa.close();
  }
});

test('answers null when no editor is active, and reports focus', async () => {
  const saaa = new FakeSaaa(temporarySocket());
  await saaa.listen();
  const client = makeClient(saaa.socketPath, () => null);
  client.start();
  try {
    await saaa.next('hello');
    client.sendFocus(false);
    assert.deepEqual(await saaa.next('focus'), { type: 'focus', focused: false });
    saaa.socket!.write('{"type":"context","id":1}\n');
    assert.deepEqual(await saaa.next('context'), { type: 'context', id: 1, context: null });
  } finally {
    client.stop();
    await saaa.close();
  }
});

test('reconnects when Saaa restarts', async () => {
  const socketPath = temporarySocket();
  const first = new FakeSaaa(socketPath);
  await first.listen();
  const client = makeClient(socketPath);
  client.start();
  try {
    await first.next('hello');
    assert.equal(client.isConnected, true);
    await first.close();
    const second = new FakeSaaa(socketPath);
    await second.listen();
    try {
      await second.next('hello');
      assert.equal(client.isConnected, true);
    } finally {
      client.stop();
      await second.close();
    }
  } finally {
    client.stop();
  }
});

test('stays quiet until Saaa is running, and never sends without a request', async () => {
  const socketPath = temporarySocket();
  const client = makeClient(socketPath);
  client.start();
  try {
    await new Promise((resolve) => setTimeout(resolve, 60));
    assert.equal(client.isConnected, false);
    const saaa = new FakeSaaa(socketPath);
    await saaa.listen();
    try {
      await saaa.next('hello');
      await new Promise((resolve) => setTimeout(resolve, 60));
      assert.deepEqual(saaa.messages.map((message) => message.type), ['hello']);
    } finally {
      await saaa.close();
    }
  } finally {
    client.stop();
  }
});

test('connects only to a socket, not to a plain file', () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'saaa-')), 'editor.sock');
  fs.writeFileSync(file, '');
  assert.equal(socketLooksRight(file), false);
  assert.equal(socketLooksRight(file + '.missing'), false);
});
