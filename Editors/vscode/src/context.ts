import type { EditorContext, Problem, Region, TerminalRun } from './protocol';
import { safeSlice } from './text';

export const LIMITS = {
  /** Lines of code sent from the screen, nearest the cursor first. */
  visibleLines: 200,
  lineChars: 400,
  selectionChars: 6_000,
  problems: 20,
  messageChars: 400,
  /** Off-screen errors that get a few lines of code around them. */
  snippets: 3,
  snippetRadius: 2,
  /** Lines around the cursor when the editor reports nothing on screen. */
  fallbackRadius: 40,
};

/** What the extension sees of the active editor, as plain data so it can be tested without VS Code. */
export interface EditorView {
  file: string | null;
  language: string;
  lineCount: number;
  /** Line ranges on screen, numbered from 0, inclusive, top to bottom. */
  visible: Array<{ start: number; end: number }>;
  /** Numbered from 0. */
  cursorLine: number;
  /** Empty when nothing is selected. */
  selection: string;
  /** Lines numbered from 0. */
  problems: Array<{ line: number; severity: 'error' | 'warning'; message: string; source?: string; code?: string }>;
  lineAt(index: number): string;
}

/** The reply to Saaa's request: null when no text editor is active, so Saaa reads the screen instead. */
export function buildContext(view: EditorView | null, terminal: TerminalRun | null): EditorContext | null {
  if (!view || view.lineCount <= 0) return null;
  const onScreen = visibleLines(view);
  const shown = new Set(onScreen);
  const problems = [...view.problems]
    .sort(
      (a, b) =>
        rank(a.severity) - rank(b.severity) ||
        Math.abs(a.line - view.cursorLine) - Math.abs(b.line - view.cursorLine) ||
        a.line - b.line,
    )
    .slice(0, LIMITS.problems);

  const near = new Set<number>();
  for (const problem of problems.filter((p) => p.severity === 'error' && !shown.has(p.line)).slice(0, LIMITS.snippets)) {
    for (let line = problem.line - LIMITS.snippetRadius; line <= problem.line + LIMITS.snippetRadius; line++) {
      if (line >= 0 && line < view.lineCount && !shown.has(line)) near.add(line);
    }
  }

  return {
    file: view.file,
    language: view.language || null,
    lineCount: view.lineCount,
    cursorLine: view.cursorLine + 1,
    visible: regions(onScreen, view),
    snippets: regions([...near].sort((a, b) => a - b), view),
    selection: view.selection.trim().length > 0 ? clip(view.selection, LIMITS.selectionChars) : null,
    problems: problems.map(toProblem),
    terminal,
  };
}

/** Lines on screen, numbered from 0, capped to the ones nearest the cursor. */
function visibleLines(view: EditorView): number[] {
  const ranges = view.visible.length > 0
    ? view.visible
    : [{ start: view.cursorLine - LIMITS.fallbackRadius, end: view.cursorLine + LIMITS.fallbackRadius }];
  const lines = new Set<number>();
  for (const range of ranges) {
    const first = Math.max(0, range.start);
    const last = Math.min(view.lineCount - 1, range.end);
    for (let line = first; line <= last; line++) lines.add(line);
  }
  const sorted = [...lines].sort((a, b) => a - b);
  if (sorted.length <= LIMITS.visibleLines) return sorted;
  return [...sorted]
    .sort((a, b) => Math.abs(a - view.cursorLine) - Math.abs(b - view.cursorLine) || a - b)
    .slice(0, LIMITS.visibleLines)
    .sort((a, b) => a - b);
}

/** Groups sorted line numbers into runs of consecutive lines. */
function regions(lines: number[], view: EditorView): Region[] {
  const result: Region[] = [];
  let run: number[] = [];
  const flush = () => {
    if (run.length === 0) return;
    result.push({ startLine: run[0] + 1, text: run.map((line) => clip(view.lineAt(line), LIMITS.lineChars)).join('\n') });
    run = [];
  };
  for (const line of lines) {
    if (run.length > 0 && line !== run[run.length - 1] + 1) flush();
    run.push(line);
  }
  flush();
  return result;
}

function toProblem(problem: EditorView['problems'][number]): Problem {
  const result: Problem = {
    line: problem.line + 1,
    severity: problem.severity,
    message: clip(problem.message.replace(/\s*\n\s*/g, ' '), LIMITS.messageChars),
  };
  if (problem.source) result.source = problem.source;
  if (problem.code) result.code = problem.code;
  return result;
}

function rank(severity: 'error' | 'warning'): number {
  return severity === 'error' ? 0 : 1;
}

export function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  return safeSlice(text, 0, max) + '…';
}
