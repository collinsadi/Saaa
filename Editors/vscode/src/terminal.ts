import { stripAnsi, tail } from './ansi';
import type { TerminalRun } from './protocol';

export const TERMINAL_LIMITS = {
  /** Raw output kept per running command, from the end. */
  keepChars: 64_000,
  lines: 80,
  chars: 6_000,
  /** A failure older than this is no longer sent. */
  maxAgeMs: 15 * 60_000,
  /** How long to wait for the last output after a command ends. */
  settleMs: 300,
};

/** Exit codes that mean the user stopped the command, not that it failed. */
const INTERRUPTED = new Set([130, 143]);

interface Running {
  terminal: unknown;
  chunks: string[];
  size: number;
  done: Promise<void>;
}

interface Failure extends TerminalRun {
  terminal: unknown;
  at: number;
}

/** Remembers the last failed terminal command and the end of its output, in memory only. */
export class TerminalTracker {
  private readonly running = new Map<object, Running>();
  private failure: Failure | null = null;
  /** Bumped by clear(), so a command still settling when sharing turns off is dropped. */
  private generation = 0;

  constructor(private readonly now: () => number = Date.now) {}

  /** Call as soon as a command starts: output written before `read()` is lost. */
  started(execution: object, terminal: unknown, stream: AsyncIterable<string>): void {
    const entry: Running = { terminal, chunks: [], size: 0, done: Promise.resolve() };
    entry.done = (async () => {
      try {
        for await (const chunk of stream) {
          entry.chunks.push(chunk);
          entry.size += chunk.length;
          while (entry.size > TERMINAL_LIMITS.keepChars && entry.chunks.length > 1) {
            entry.size -= entry.chunks.shift()!.length;
          }
        }
      } catch {
        // The terminal went away mid-command; keep what arrived.
      }
    })();
    this.running.set(execution, entry);
  }

  /** Only commands this tracker saw start are remembered: one that began while sharing was off stays unknown. */
  async ended(execution: object, terminal: unknown, command: string, exitCode: number | undefined): Promise<void> {
    const entry = this.running.get(execution);
    this.running.delete(execution);
    if (exitCode === 0) {
      if (this.failure?.terminal === terminal) this.failure = null;
      return;
    }
    if (!entry || exitCode === undefined || INTERRUPTED.has(exitCode) || command.trim().length === 0) return;
    const generation = this.generation;
    await Promise.race([entry.done, delay(TERMINAL_LIMITS.settleMs)]);
    if (generation !== this.generation) return;
    const output = tail(stripAnsi(entry.chunks.join('')), TERMINAL_LIMITS.lines, TERMINAL_LIMITS.chars);
    this.failure = { command: command.trim(), exitCode, output, terminal, at: this.now() };
  }

  closed(terminal: unknown): void {
    if (this.failure?.terminal === terminal) this.failure = null;
    for (const [execution, entry] of this.running) {
      if (entry.terminal === terminal) this.running.delete(execution);
    }
  }

  lastFailure(): TerminalRun | null {
    if (!this.failure || this.now() - this.failure.at > TERMINAL_LIMITS.maxAgeMs) return null;
    const { command, exitCode, output } = this.failure;
    return { command, exitCode, output };
  }

  clear(): void {
    this.generation += 1;
    this.running.clear();
    this.failure = null;
  }
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
