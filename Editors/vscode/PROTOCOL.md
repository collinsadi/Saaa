# Editor protocol

The Saaa Mac app and editor extensions talk over a Unix stream socket at `~/Library/Application Support/Saaa/editor.sock`. Saaa creates it at launch with mode 0600 inside a folder only the user can open, and accepts connections only from processes of the same user (`getpeereid`). Each message is one JSON object on one line (UTF-8, `\n`-terminated). Protocol version: 1.

The extension connects and introduces itself. After that it speaks only when spoken to, apart from focus changes, which carry no content.

## Extension to Saaa

`hello`, once per connection:

```json
{"type":"hello","protocol":1,"app":"Visual Studio Code","scheme":"vscode","version":"1.105.1","extension":"0.1.0","workspace":"saaa","focused":true}
```

`workspace` helps Saaa pick the right window when several are open; it never leaves the Mac.

`focus`, when the editor window gains or loses focus:

```json
{"type":"focus","focused":false}
```

`context`, the reply to a request, with the same `id`. `context` is `null` when no text editor is active, and Saaa then reads the screen instead:

```json
{"type":"context","id":7,"context":{
  "file":"src/app.ts","language":"typescript","lineCount":10,"cursorLine":5,
  "visible":[{"startLine":1,"text":"..."},{"startLine":9,"text":"..."}],
  "snippets":[],
  "selection":"item.value",
  "problems":[{"line":5,"severity":"error","message":"Property 'value' does not exist on type 'number'.","source":"ts","code":"2339"}],
  "terminal":{"command":"npm test","exitCode":1,"output":"FAIL src/app.test.ts"}
}}
```

Lines are numbered from 1. A region's `text` is its lines joined with `\n`, with no newline after the last one, so a region that ends on a blank line ends in `\n`. `visible` holds the lines on screen, split where code is folded, at most 200 lines nearest the cursor. `snippets` holds a few lines around up to three errors that are scrolled out of view. `problems` lists errors first, then warnings, nearest the cursor first, at most 20. `terminal` is the last failed command in the last 15 minutes, or `null`.

[`test/fixtures/context.json`](test/fixtures/context.json) is a complete example. Both the extension's tests and Saaa's Swift tests (`EditorBridgeTests`) check it, so the two sides can't drift apart.

## Saaa to extension

`welcome`, once per connection: `{"type":"welcome","protocol":1}`.

`context`, a request: `{"type":"context","id":7}`. Saaa sends one only when the user presses Look or Watch reads, and waits about a third of a second before falling back to reading the screen.

## Choosing a window

Each editor window runs its own extension host, so each window is its own connection. Saaa asks the window that belongs to the app in front: it matches the app by process ancestry (the kernel reports each connection's process), then prefers the focused window, then the window whose workspace name is in the front window's title, then the window focused most recently.
