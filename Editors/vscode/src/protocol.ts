// The messages between this extension and the Saaa Mac app, one JSON object
// per line over a Unix socket that only the user's account can open. See
// PROTOCOL.md for the full description.

export const PROTOCOL = 1;

/** A run of consecutive lines, numbered from 1. */
export interface Region {
  startLine: number;
  text: string;
}

/** An error or warning the editor shows for the file. */
export interface Problem {
  /** Numbered from 1. */
  line: number;
  severity: 'error' | 'warning';
  message: string;
  source?: string;
  code?: string;
}

/** The most recent terminal command that failed, with the end of its output. */
export interface TerminalRun {
  command: string;
  exitCode: number | null;
  output: string;
}

/** What the active editor shows, sent only when Saaa asks for it. */
export interface EditorContext {
  /** Workspace-relative path, or a file name. */
  file: string | null;
  language: string | null;
  lineCount: number | null;
  /** Numbered from 1. */
  cursorLine: number | null;
  /** The lines on screen; folded code splits them into regions. */
  visible: Region[];
  /** A few lines around errors that are scrolled out of view. */
  snippets: Region[];
  selection: string | null;
  problems: Problem[];
  terminal: TerminalRun | null;
}

/** Sent once after connecting. The workspace name helps Saaa tell windows apart; it is never sent to Claude. */
export interface Hello {
  type: 'hello';
  protocol: number;
  app: string;
  scheme: string;
  version: string;
  extension: string;
  workspace: string | null;
  focused: boolean;
}

export interface Focus {
  type: 'focus';
  focused: boolean;
}

export interface ContextReply {
  type: 'context';
  id: number;
  context: EditorContext | null;
}

/** Saaa's request for the current context. */
export interface ContextRequest {
  type: 'context';
  id: number;
}
