import * as fs from 'node:fs';
import * as net from 'node:net';
import { LineReader } from './lines';
import { PROTOCOL, type ContextReply, type EditorContext, type Focus, type Hello } from './protocol';

export interface ClientOptions {
  socketPath: string;
  /** Who this window is; sent once per connection. */
  hello: () => Omit<Hello, 'type' | 'protocol'>;
  /** The reply to a request: called only when Saaa asks. */
  context: () => Promise<EditorContext | null> | EditorContext | null;
  onStateChange?: (connected: boolean) => void;
  retryMs?: { first: number; max: number };
}

/**
 * The connection to Saaa. It connects when Saaa is running, retries with a
 * growing delay when it isn't, and answers context requests. It never sends
 * editor text unless Saaa asks.
 */
export class BridgeClient {
  private socket: net.Socket | null = null;
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private connected = false;
  private delay: number;

  constructor(private readonly options: ClientOptions) {
    this.delay = this.firstDelay;
  }

  get isConnected(): boolean {
    return this.connected;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const socket = this.socket;
    this.socket = null;
    socket?.destroy();
    this.setConnected(false);
    this.delay = this.firstDelay;
  }

  sendFocus(focused: boolean): void {
    const message: Focus = { type: 'focus', focused };
    this.write(message);
  }

  private get firstDelay(): number {
    return this.options.retryMs?.first ?? 2_000;
  }

  private connect(): void {
    this.timer = null;
    if (!this.running || this.socket) return;
    if (!socketLooksRight(this.options.socketPath)) {
      this.retry();
      return;
    }
    const socket = net.createConnection({ path: this.options.socketPath });
    this.socket = socket;
    socket.setEncoding('utf8');
    const reader = new LineReader();
    socket.on('connect', () => {
      if (this.socket !== socket) return;
      this.delay = this.firstDelay;
      this.setConnected(true);
      const hello: Hello = { type: 'hello', protocol: PROTOCOL, ...this.options.hello() };
      this.write(hello);
    });
    socket.on('data', (chunk: string) => {
      let lines: string[];
      try {
        lines = reader.push(chunk);
      } catch {
        socket.destroy();
        return;
      }
      for (const line of lines) void this.handle(line, socket);
    });
    socket.on('error', () => {
      // 'close' follows and schedules the retry.
    });
    socket.on('close', () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.setConnected(false);
      this.retry();
    });
  }

  private retry(): void {
    if (!this.running || this.timer) return;
    const wait = this.delay;
    this.delay = Math.min(this.delay * 2, this.options.retryMs?.max ?? 30_000);
    this.timer = setTimeout(() => this.connect(), wait);
    this.timer.unref?.();
  }

  private async handle(line: string, socket: net.Socket): Promise<void> {
    let message: { type?: unknown; id?: unknown };
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (message.type !== 'context' || typeof message.id !== 'number') return;
    let context: EditorContext | null = null;
    try {
      context = await this.options.context();
    } catch {
      context = null;
    }
    if (this.socket !== socket) return;
    const reply: ContextReply = { type: 'context', id: message.id, context };
    this.write(reply);
  }

  private write(message: object): void {
    if (!this.socket || !this.connected) return;
    this.socket.write(JSON.stringify(message) + '\n');
  }

  private setConnected(connected: boolean): void {
    if (this.connected === connected) return;
    this.connected = connected;
    this.options.onStateChange?.(connected);
  }
}

/** Connect only to a socket owned by this user: Saaa creates it in its own folder, readable by the owner only. */
export function socketLooksRight(path: string): boolean {
  try {
    const stat = fs.statSync(path);
    const uid = typeof process.getuid === 'function' ? process.getuid() : undefined;
    return stat.isSocket() && (uid === undefined || stat.uid === uid);
  } catch {
    return false;
  }
}
