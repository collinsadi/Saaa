import assert from 'node:assert/strict';
import { test } from 'node:test';
import { TERMINAL_LIMITS, TerminalTracker } from '../src/terminal';

async function* output(...chunks: string[]): AsyncIterable<string> {
  for (const chunk of chunks) yield chunk;
}

test('remembers a failed command with the end of its plain output', async () => {
  const tracker = new TerminalTracker();
  const execution = {};
  const terminal = {};
  tracker.started(execution, terminal, output('\u001b[32mrunning\u001b[0m\r\n', 'Error: expected 3, got 4\r\n'));
  await tracker.ended(execution, terminal, ' npm test ', 1);
  assert.deepEqual(tracker.lastFailure(), { command: 'npm test', exitCode: 1, output: 'running\nError: expected 3, got 4' });
});

test('a later success in the same terminal clears the failure', async () => {
  const tracker = new TerminalTracker();
  const terminal = {};
  const first = {};
  tracker.started(first, terminal, output('boom\n'));
  await tracker.ended(first, terminal, 'make', 2);
  const second = {};
  tracker.started(second, terminal, output('ok\n'));
  await tracker.ended(second, terminal, 'make', 0);
  assert.equal(tracker.lastFailure(), null);
});

test('a success in another terminal keeps the failure', async () => {
  const tracker = new TerminalTracker();
  const failing = {};
  tracker.started(failing, 'a', output('boom\n'));
  await tracker.ended(failing, 'a', 'make', 2);
  const passing = {};
  tracker.started(passing, 'b', output('ok\n'));
  await tracker.ended(passing, 'b', 'ls', 0);
  assert.equal(tracker.lastFailure()?.command, 'make');
});

test('interrupted commands and unknown results are not failures', async () => {
  const tracker = new TerminalTracker();
  const stopped = {};
  tracker.started(stopped, 't', output('^C\n'));
  await tracker.ended(stopped, 't', 'npm run dev', 130);
  const unknown = {};
  tracker.started(unknown, 't', output('?\n'));
  await tracker.ended(unknown, 't', 'make', undefined);
  assert.equal(tracker.lastFailure(), null);
});

test('old failures expire and closing the terminal forgets them', async () => {
  let now = 0;
  const tracker = new TerminalTracker(() => now);
  const execution = {};
  tracker.started(execution, 't', output('boom\n'));
  await tracker.ended(execution, 't', 'make', 1);
  now = TERMINAL_LIMITS.maxAgeMs + 1;
  assert.equal(tracker.lastFailure(), null);
  now = 0;
  assert.notEqual(tracker.lastFailure(), null);
  tracker.closed('t');
  assert.equal(tracker.lastFailure(), null);
});

test('keeps only the end of a long output', async () => {
  const tracker = new TerminalTracker();
  const execution = {};
  const lines = Array.from({ length: 500 }, (_, i) => `line ${i}\n`);
  tracker.started(execution, 't', output(...lines));
  await tracker.ended(execution, 't', 'make', 1);
  const failure = tracker.lastFailure()!;
  assert.equal(failure.output.split('\n').length, TERMINAL_LIMITS.lines);
  assert.ok(failure.output.endsWith('line 499'));
});

test('a command that started while sharing was off is never remembered', async () => {
  const tracker = new TerminalTracker();
  await tracker.ended({}, 't', 'mysql -pS3cret prod', 1);
  assert.equal(tracker.lastFailure(), null);
});

test('turning sharing off while a command settles drops it', async () => {
  const tracker = new TerminalTracker();
  const execution = {};
  let finish: () => void = () => {};
  const held = new Promise<void>((resolve) => { finish = resolve; });
  async function* slow(): AsyncIterable<string> {
    yield 'boom\n';
    await held;
  }
  tracker.started(execution, 't', slow());
  const ending = tracker.ended(execution, 't', 'make', 2);
  tracker.clear();
  finish();
  await ending;
  assert.equal(tracker.lastFailure(), null);
});
