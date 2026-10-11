# Saaa for VS Code

This extension lets [Saaa](https://github.com/collinsadi/Saaa), the Mac copilot for calls and code, read your editor exactly instead of reading the screen. When you press Look (⌥⌘L) or turn on Watch in Saaa's Code Assist, Saaa asks this extension for:

- the lines you can see, with line numbers,
- the file's errors and warnings,
- what you selected,
- the last terminal command that failed and the end of its output.

It works in VS Code, Cursor, Windsurf and other editors built on VS Code, on macOS.

## Privacy

- The extension never sends anything on its own. It answers only when Saaa asks, and Saaa asks only when you press Look or Watch reads.
- It talks to Saaa over a Unix socket in Saaa's own folder (`~/Library/Application Support/Saaa/editor.sock`) that only your macOS account can open. This extension makes no network requests.
- Saaa masks secrets such as API keys and passwords before anything goes to Claude, and shows you exactly what was sent.
- Terminal output is kept in memory, only for the last failed command, and forgotten after 15 minutes or when the terminal closes.
- Turn it off any time with **Saaa: Turn Editor Sharing On or Off** or the `saaa.enabled` setting. Saaa then reads the screen as before.

A `Saaa` item shows in the status bar while Saaa is connected.

## Install

Until it's on the Marketplace, build it from Saaa's source:

```sh
cd Editors/vscode
npm install
npm run package
code --install-extension saaa-0.1.0.vsix
```

In Cursor use `cursor --install-extension`, and in Windsurf `windsurf --install-extension`.

## Settings

| Setting | Default | Does |
|---|---|---|
| `saaa.enabled` | On | Let Saaa read this editor when you press Look or Watch is on |
| `saaa.shareTerminal` | On | Include the last failed terminal command and the end of its output |

Terminal output needs VS Code's shell integration, which is on by default. Remote windows (SSH, containers) are untested: the extension runs on your Mac, next to Saaa.

## Development

```sh
npm install
npm test
```

The tests run without VS Code: the context builder, the terminal tracker and the socket client are plain TypeScript. [PROTOCOL.md](PROTOCOL.md) describes the messages.
