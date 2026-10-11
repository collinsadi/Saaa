import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import * as path from 'node:path';
import { test } from 'node:test';
import { buildContext, LIMITS, type EditorView } from '../src/context';

function view(lines: string[], overrides: Partial<EditorView> = {}): EditorView {
  return {
    file: 'src/app.ts',
    language: 'typescript',
    lineCount: lines.length,
    visible: [{ start: 0, end: lines.length - 1 }],
    cursorLine: 0,
    selection: '',
    problems: [],
    lineAt: (index) => lines[index],
    ...overrides,
  };
}

/** The canonical example shared with Saaa's Swift tests (EditorBridgeTests). */
export function canonicalView(): EditorView {
  const lines = [
    'import { load } from "./load";',
    '',
    'export function total(items: number[]): number {',
    '  let sum = 0;',
    '  for (const item of items) sum += item.value;',
    '  return sum;',
    '}',
    '',
    'export const answer = total(load());',
    'const unused = 1;',
  ];
  return view(lines, {
    visible: [{ start: 0, end: 6 }, { start: 8, end: 8 }],
    cursorLine: 4,
    selection: 'item.value',
    problems: [
      { line: 9, severity: 'warning', message: "'unused' is declared but its value is never read.", source: 'ts', code: '6133' },
      { line: 4, severity: 'error', message: "Property 'value' does not exist\non type 'number'.", source: 'ts', code: '2339' },
    ],
  });
}

test('the canonical example matches the shared fixture', () => {
  const context = buildContext(canonicalView(), { command: 'npm test', exitCode: 1, output: 'FAIL src/app.test.ts\n  total adds values' });
  const fixture = JSON.parse(readFileSync(path.join(__dirname, '..', '..', 'test', 'fixtures', 'context.json'), 'utf8'));
  assert.deepEqual(context, fixture);
});

test('no active editor means no context', () => {
  assert.equal(buildContext(null, null), null);
  assert.equal(buildContext(null, { command: 'make', exitCode: 2, output: '' }), null);
});

test('folded code splits the screen into regions numbered from 1', () => {
  const context = buildContext(canonicalView(), null)!;
  assert.deepEqual(context.visible.map((region) => region.startLine), [1, 9]);
  assert.equal(context.visible[0].text.split('\n').length, 7);
  assert.equal(context.cursorLine, 5);
});

test('errors come first, then the nearest warnings, with one-line messages', () => {
  const context = buildContext(canonicalView(), null)!;
  assert.deepEqual(context.problems.map((problem) => problem.severity), ['error', 'warning']);
  assert.equal(context.problems[0].message, "Property 'value' does not exist on type 'number'.");
  assert.equal(context.problems[0].line, 5);
});

test('an error scrolled out of view gets a few lines around it', () => {
  const lines = Array.from({ length: 100 }, (_, i) => `line ${i + 1}`);
  const context = buildContext(
    view(lines, {
      visible: [{ start: 0, end: 19 }],
      problems: [{ line: 59, severity: 'error', message: 'boom' }, { line: 79, severity: 'warning', message: 'meh' }],
    }),
    null,
  )!;
  assert.deepEqual(context.snippets, [{ startLine: 58, text: 'line 58\nline 59\nline 60\nline 61\nline 62' }]);
});

test('a tall screen keeps the lines nearest the cursor', () => {
  const lines = Array.from({ length: 1_000 }, (_, i) => `line ${i + 1}`);
  const context = buildContext(view(lines, { visible: [{ start: 0, end: 999 }], cursorLine: 500 }), null)!;
  const shown = context.visible.flatMap((region) => region.text.split('\n'));
  assert.equal(shown.length, LIMITS.visibleLines);
  assert.ok(shown.includes('line 501'));
  assert.equal(context.visible[0].startLine, 401);
});

test('long lines, selections and messages are clipped', () => {
  const long = 'x'.repeat(LIMITS.lineChars + 50);
  const context = buildContext(
    view([long], {
      selection: 'y'.repeat(LIMITS.selectionChars + 1),
      problems: [{ line: 0, severity: 'error', message: 'z'.repeat(LIMITS.messageChars + 1) }],
    }),
    null,
  )!;
  assert.equal(context.visible[0].text.length, LIMITS.lineChars + 1);
  assert.equal(context.selection!.length, LIMITS.selectionChars + 1);
  assert.ok(context.selection!.endsWith('…'));
  assert.equal(context.problems[0].message.length, LIMITS.messageChars + 1);
});

test('a blank selection is no selection', () => {
  assert.equal(buildContext(view(['a'], { selection: '  \n ' }), null)!.selection, null);
});

test('clipping never splits an emoji, so the reply stays valid Unicode', () => {
  const line = 'x'.repeat(LIMITS.lineChars - 1) + '😀 and more';
  const context = buildContext(view([line]), null)!;
  const text = context.visible[0].text;
  assert.ok(!/[\ud800-\udbff]…$/.test(text));
  assert.doesNotThrow(() => encodeURIComponent(text));
  assert.ok(!JSON.stringify(context).includes('\\ud83d'));
});
