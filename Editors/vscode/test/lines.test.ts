import assert from 'node:assert/strict';
import { test } from 'node:test';
import { LineReader } from '../src/lines';

test('joins chunks into whole lines and skips blank ones', () => {
  const reader = new LineReader();
  assert.deepEqual(reader.push('{"a":'), []);
  assert.deepEqual(reader.push('1}\n\n{"b"'), ['{"a":1}']);
  assert.deepEqual(reader.push(':2}\n'), ['{"b":2}']);
});

test('refuses a line that never ends', () => {
  const reader = new LineReader(8);
  assert.throws(() => reader.push('0123456789'));
  assert.deepEqual(reader.push('ok\n'), ['ok']);
});
