<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset=".github/assets/lockup-dark.svg">
    <img src=".github/assets/lockup-light.svg" alt="Saaa" width="240">
  </picture>
</p>

<p align="center"><b>A copilot for every call.</b></p>

Saaa is a native macOS app that hears both sides of your calls on your Mac and helps while you talk. It keeps a live transcript, answers what the other side just asked in about a second, suggests what to say or ask next, and keeps running notes. When you hang up, the summary is already being written, and you can ask any past call a question.

It works with any call app: Zoom, Meet in a browser, Teams, FaceTime, Slack huddles. There is no bot in the meeting and nothing to install for the other people.

## How it works

**Before the call.** When a calendar meeting with a video link starts, or a call app starts using audio, the island under the notch offers to start, with a playbook picked from the meeting title. Click it or press ⌥⌘R. Prep is optional: add a goal, who's on the call and notes, or fill them from the calendar.

**During the call.** The island stays black and fused with the notch: recording lamp, timer, levels. Click it and a Liquid Glass panel drops down with:

- an answer card that streams in about a second, with one line you can say first and the facts behind it,
- quick actions from the playbook (Answer, What to say, What to ask, Catch me up, plus extras like Handle objection), on ⌘1 to ⌘4,
- an Ask field for anything else (⌥⌘K from any app, ⌘↩ to answer what they just asked),
- **Look** (⌥⌘L, or the viewfinder by the Ask field): Saaa reads the window in front of you and answers with the call and the screen together. An error gets the fix, a coding problem gets the approach, and anything typed in Ask becomes your question about the screen,
- a "They asked" chip when someone asks you a question, with one-tap or automatic answers; automatic answers can start before they finish asking,
- live notes: key points, decisions, action items and open questions,
- the live transcript, Me and Them, with words in progress shown lighter.

**After the call.** Stop and the transcript is final. The summary arrives seeded by the live notes: TL;DR, decisions, action items with owners, open questions, the playbook's own sections and an optional follow-up email. Copy it, save it to a folder you choose once (a repo's docs folder or a notes vault), export Markdown or HTML with optional redaction, or open Ask this call. You can also drop in a recording and get the same transcript and summary.

## Playbooks

A playbook tells the copilot who you are on this kind of call: instructions in your own words, quick actions, words to listen for (they also tune transcription), reference material such as pricing sheets or rubrics, summary sections and whether to answer questions automatically. Eight come built in: General, Sales, Customer Success, Recruiting (interviewer side), Investor pitch, Standup, 1:1 and Lecture. Edit them or make your own.

## Privacy and data flow

- **Audio never leaves your Mac.** Your microphone and the call app's audio are captured as two separate streams and transcribed by Apple's on-device speech model.
- **Only text goes to Claude, through your Saaa server.** You bring your own Anthropic key. It's sent once to the Saaa relay, a small server you host (see [Server](Server/README.md)), which checks it with Anthropic, encrypts it with AES-256-GCM and keeps it. This Mac stores only an access token, so nothing lives in the Keychain and there are no password prompts. When the copilot answers, writes notes, summarizes or answers Ask this call, transcript text, your playbook, your prep notes and, when you press Look, text read from your screen pass through the relay to Anthropic. The relay doesn't log or keep them. Nothing is sent while the copilot is idle.
- **Look sends text, not pixels, and only when you ask.** Look takes one frame of the window in front, reads its text on this Mac with Apple's Vision, masks secrets such as API keys, tokens, private keys and passwords, and sends that text with the transcript. The image is never saved or sent. The text stays in memory so the panel can show exactly what was sent, and it isn't saved with the session. Look needs Screen Recording permission. When someone shares their screen, Look reads what you can see, so treat it like your notes and tell people.
- **Encrypted at rest.** Transcripts, notes, summaries and playbooks are sealed with AES-GCM on this Mac, with a key kept in Saaa's own folder that only your macOS account can read. Audio files are deleted once the transcript is saved unless you choose to keep them.
- **No telemetry.** Logs record state changes and error codes, never call content.
- **Consent is visible.** A recording indicator is always on screen while Saaa records, and nothing starts without you. Saaa reminds you to tell people and gives you a line to paste into the chat. Recording laws vary by place; telling people is your responsibility.
- **Screen Privacy is your choice.** Off by default. When on, Saaa's windows are left out of screenshots and shared screens. It can't hide anything from a camera, and it doesn't replace telling people.

## Cost

You pay Anthropic directly for what you use. With the default models (Claude Haiku 5.5 for live help and notes, Claude Sonnet 5.5 for summaries and Ask this call), an hour-long call with regular live help typically costs a few cents. Prompts are shaped for caching, so each live answer pays full price only for the newest part of the conversation. Every session records its usage, and Settings shows this month's total. Models can be changed per role.

## Download

Get `Saaa.dmg` from the [latest release](https://github.com/collinsadi/Saaa/releases/latest), open it and drag Saaa into Applications. It's signed and notarized.

## Requirements

- Apple silicon Mac with macOS 26 or newer.
- A Claude API key from the [Claude Console](https://console.anthropic.com/settings/keys), connected in Settings. It's kept on your Saaa relay; see [`Server/`](Server/README.md) to run your own. Without a key, Saaa still records and transcribes.
- Xcode 27 or newer to build.

## Build and run

```sh
git clone https://github.com/collinsadi/Saaa.git
cd Saaa
xcodebuild -project Saaa.xcodeproj -scheme Saaa -configuration Debug build
```

Copy the built app to Applications and launch it from there. First run walks you through what Saaa does with your audio, the permissions it needs (microphone, system audio and optionally calendar), your Claude API key, the speech model download and a default playbook. Every step can be skipped and run again from Settings.

Tests live in each local package:

```sh
for p in Packages/*/; do (cd "$p" && swift test); done
```

The relay has its own tests, run against a fake Anthropic:

```sh
cd Server && go test ./...
```

The Claude integration tests stay off unless you opt in with your own key:

```sh
cd Packages/AnthropicKit && SAAA_LIVE_API=1 ANTHROPIC_API_KEY=... swift test --filter Live
```

## Shortcuts

| Keys | Does |
|---|---|
| ⌥⌘R | Start or stop a session, from any app |
| ⌥⌘A | Answer what they just asked |
| ⌥⌘K | Open the live panel with Ask focused |
| ⌥⌘L | Look at your screen (during a session) |
| ⌘1 to ⌘4 | Quick actions, in the live panel |
| ⌘↩ | In the Ask field: answer the latest question |

## Project layout

One app target over ten local Swift packages, Swift 6 with strict concurrency throughout:

| Package | Role |
|---|---|
| Core | Transcript, playbook, summary, usage and screen-snapshot models; question detection; redaction of exports and screen text; Screen Privacy policy |
| AnthropicKit | Streaming Messages API client, structured output, model catalog and pricing, Saaa relay connection |
| AudioCapture | Core Audio process taps and microphone capture, lock-free hot path, live 16 kHz sample stream |
| Transcription | SpeechAnalyzer lanes per side, live transcript with echo guard, speech asset install, file transcription |
| ScreenContext | Look: front-window capture, on-device text recognition and layout, scene detection |
| Copilot | Cache-shaped prompt composer, copilot engine, live notes, summaries, Ask this call |
| CallSession | Session lifecycle, global hotkeys, meeting detection, imports |
| CalendarContext | EventKit reader for current and upcoming meetings |
| Persistence | AES-GCM sealing, session library and search, playbook store, export, migration |
| DesignSystem | Tokens, Liquid Glass modifiers and shared components |

The Saaa relay lives in [`Server/`](Server/README.md): a Go service, standard library only, that keeps each user's Anthropic key sealed and streams requests through.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). AI agents contributing code must follow [AI_POLICY.md](AI_POLICY.md). Security reports go through [SECURITY.md](SECURITY.md).

## License

[Apache License 2.0](LICENSE). Copyright 2026 Collins Adi.
