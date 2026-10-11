import { safeSlice } from './text';

// Escape sequences a terminal understands: CSI (colors, cursor moves), OSC
// (titles, hyperlinks, shell integration marks), DCS-style strings and the
// short two-byte forms.
const SEQUENCE =
  /\u001b\[[0-?]*[ -/]*[@-~]|\u009b[0-?]*[ -/]*[@-~]|\u001b\][\s\S]*?(?:\u0007|\u001b\\)|\u001b[PX^_][\s\S]*?\u001b\\|\u001b[@-Z\\-_]/g;

/**
 * Plain text from raw terminal output: no escape sequences, and a line that
 * was redrawn with a carriage return (a progress bar) keeps only its final state.
 */
export function stripAnsi(raw: string): string {
  return raw
    .replace(SEQUENCE, '')
    .split('\n')
    .map((line) => {
      const trimmed = line.endsWith('\r') ? line.slice(0, -1) : line;
      const redraw = trimmed.lastIndexOf('\r');
      return redraw >= 0 ? trimmed.slice(redraw + 1) : trimmed;
    })
    .join('\n');
}

/** The last `maxLines` lines and at most `maxChars` characters, starting at a line break, trailing blank lines dropped. */
export function tail(text: string, maxLines: number, maxChars: number): string {
  const lines = text.trimEnd().split('\n');
  let kept = lines.slice(-maxLines).join('\n');
  if (kept.length > maxChars) {
    kept = safeSlice(kept, kept.length - maxChars, kept.length);
    const firstBreak = kept.indexOf('\n');
    if (firstBreak >= 0) kept = kept.slice(firstBreak + 1);
  }
  return kept;
}
