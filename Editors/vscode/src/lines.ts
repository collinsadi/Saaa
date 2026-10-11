/** Splits a text stream into newline-terminated messages. */
export class LineReader {
  private buffer = '';

  constructor(private readonly maxLength = 1_000_000) {}

  /** The complete, non-empty lines so far. Throws if one line grows past the limit. */
  push(chunk: string): string[] {
    this.buffer += chunk;
    const lines = this.buffer.split('\n');
    this.buffer = lines.pop() ?? '';
    if (this.buffer.length > this.maxLength) {
      this.buffer = '';
      throw new Error('message too long');
    }
    return lines.filter((line) => line.trim().length > 0);
  }
}
