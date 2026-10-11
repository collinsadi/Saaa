import assert from 'node:assert/strict';
import { test } from 'node:test';
import { stripAnsi, tail } from '../src/ansi';

test('removes colors, cursor moves and shell integration marks', () => {
  const raw = '\u001b]633;C\u0007\u001b[31merror\u001b[0m: cannot find module \u001b[1m\'x\'\u001b[22m\r\n\u001b]633;D;1\u0007';
  assert.equal(stripAnsi(raw), "error: cannot find module 'x'\n");
});

test('keeps only the final state of a redrawn line', () => {
  assert.equal(stripAnsi('Compiling 10%\rCompiling 50%\rCompiling done\nnext'), 'Compiling done\nnext');
});

test('removes hyperlinks but keeps their text', () => {
  assert.equal(stripAnsi('see \u001b]8;;https://example.com\u001b\\the docs\u001b]8;;\u001b\\ now'), 'see the docs now');
});

test('tail keeps the last lines and starts at a line break', () => {
  const text = Array.from({ length: 10 }, (_, i) => `line ${i}`).join('\n') + '\n\n';
  assert.equal(tail(text, 3, 1_000), 'line 7\nline 8\nline 9');
  assert.equal(tail(text, 10, 14), 'line 8\nline 9');
  assert.equal(tail(text, 10, 12), 'line 9');
});
