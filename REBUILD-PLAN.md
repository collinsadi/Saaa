# Saaa — Rebuild Plan (v2)

> **From:** an on-device tool that files finished calls into local Claude Code projects.
> **To:** a live meeting copilot that hears both sides on-device, answers in about a second,
> takes notes while you talk, and hands you a finished summary the moment you hang up.

| | |
|---|---|
| **Document** | Rebuild plan v2. Supersedes v1 of this file and the filing roadmap in ARCHITECTURE.md §16 |
| **Date** | 2026-10-11 |
| **Status** | Built on `rebuild/live-copilot` (one commit per phase), verified on device. See §7 |
| **Baseline** | macOS 26+ only · Xcode 27+ · Swift 6 strict concurrency |
| **Reasoning** | Claude API direct (streaming Messages API), bring-your-own key in the Keychain |
| **Transcription** | Apple SpeechAnalyzer, on-device, live (replaces Whisper) |

---

## 0. What v2 changes, and why it is better than v1

| # | v1 said | v2 does | Why it matters |
|---|---|---|---|
| 1 | Build against the macOS 26 SDK, keep a macOS 15 fallback | **Require macOS 26.** One code path, real Liquid Glass everywhere | Every surface gets designed once. No material fallbacks to keep in sync |
| 2 | Rolling Whisper re-transcription of a growing tail | **Apple SpeechAnalyzer** per lane: native volatile + final results, sub-second lag | Live words appear as they are spoken. No 1.6 GB first-run download, no shared-context gate, no duplicate lines by construction |
| 3 | Live loop reads the WAV tail from disk | **Capture streams 16 kHz samples straight to the transcriber** (WAVs still written for crash safety) | Removes ~7 s of polling latency |
| 4 | "fast = Haiku, quality = Sonnet/Opus" | Current lineup: **Haiku 5.5** live, **Sonnet 5.5** summaries, **Opus 5.5** as "Best" | Haiku 5.5 is $0.10 / $0.50 per MTok with 512-token cache minimum, so live help costs cents per hour |
| 5 | "Prompt caching of the stable prefix" | **Two moving breakpoints**: playbook + context, then append-only transcript chunks | Each live turn pays full price only for the last few hundred tokens |
| 6 | Use-case modes = a system prompt | **Playbooks**: instructions, quick actions, vocabulary, knowledge files, summary sections, auto-suggest. Eight built-ins plus your own | The copilot sounds like your sales motion or your interview loop, not a generic assistant |
| 7 | Summary generated after stop | **Live notes** update during the call; the summary at stop starts from them | Summary in seconds, and you can glance at notes mid-call |
| 8 | Summary + export | Plus **Ask this call** (chat with any past session) and search across sessions | Every call stays useful after it ends |
| 9 | Hotkey starts recording | **Meeting detection**: calendar + conferencing app → the island offers "Start" with the right playbook pre-picked | Zero-thought start, still always user-initiated |
| 10 | Keep consent affordances | Plus a **one-tap disclosure line** ("I'm using an AI note-taker…") offered at start | Consent becomes an action, not just a setting |
| 11 | Cost display in Phase 9 | **Usage ledger** from day one: tokens and cost per session, per month | No surprises on the bill |
| 12 | Old filing pipeline becomes optional | **Retired**: CLI bridges, matching, write-back, Code Assist, Whisper, SwiftData | Roughly 6,000 fewer lines; no external CLI dependency |

---

## 1. The product

### 1.1 One line

Saaa listens to both sides of your call on your Mac and helps you in the moment: what they just asked, what to say, what to ask next, where the call stands. When the call ends, the summary is already written.

### 1.2 The loop

**Before.** Two minutes before a calendar meeting with a video link, or as soon as a conferencing app starts using audio, the island under the notch offers *Start* with a playbook picked from the event (an "interview" goes to Recruiting, "standup" to Standup). One click, or ⌥⌘R. *Prep* (optional) adds a goal, who's on the call, notes and links; the calendar pre-fills it.

**During.** The island stays black and fused with the notch: lamp, timer, meters. Click it and a Liquid Glass panel drops below:
- a **live transcript strip** (Me / Them, the in-progress words lighter),
- the **answer card**, streaming in about a second: one sentence you can say first, then two or three supporting facts,
- **quick actions** from the playbook: Answer · What to say · What to ask · Catch me up, plus playbook extras ("Handle objection", "Next interview question"),
- an **Ask** field (⌥⌘K focuses it from anywhere, ⌘↩ sends),
- **Notes**: running key points, decisions and action items,
- a **suggestion chip** when the other side asks something ("They asked about pricing for teams · Answer"), if auto-suggest is on.

**After.** Stop, and the transcript is already final. The summary streams in from the live notes: TL;DR, decisions, action items with owners, open questions, playbook sections (Sales: pains, budget, objections, next steps), and a follow-up email draft. Copy it, save it to a folder (a repo's `docs/meetings`, an Obsidian vault), export HTML or Markdown, or *Ask this call* anything.

### 1.3 Principles (non-negotiable)

- **Consent is visible.** A recording indicator is always on screen while capturing; the disclosure helper is one tap; nothing records silently.
- **The copilot never touches the recording.** Every API or transcription failure degrades quietly; capture keeps running.
- **Honest data flow.** Audio and transcription stay on the Mac. Transcript text, your playbook, your context and your asks go to Anthropic only when the copilot runs. The key lives in the Keychain. Content is AES-GCM encrypted at rest.
- **Calm, native, fast.** One glass layer for chrome, plain surfaces for reading. The island stays true black. Speed is a feature with a budget (§3.4).
- **Screen Privacy is a user choice**, default off, never a stealth feature: it uses the standard `NSWindow.sharingType` exclusion and the UI says plainly that a camera can still see the screen.

---

## 2. Decisions

| Area | Decision |
|---|---|
| Platform | macOS 26.0+, Apple silicon. Xcode 27+ to build (the macOS 27 SDK carries the SpeechAnalyzer resource-limit option, used behind `#available`). `MACOSX_DEPLOYMENT_TARGET = 26.0`, all packages `.macOS(.v26)` |
| Transcription | `SpeechAnalyzer` + `SpeechTranscriber` (time-indexed progressive preset), one analyzer per lane. `DictationTranscriber` when the locale is outside SpeechTranscriber's list. Custom vocabulary through `AnalysisContext.contextualStrings` |
| Reasoning | Claude Messages API over HTTPS, SSE streaming, `anthropic-version: 2023-06-01`. No server of ours in between |
| Models | Live answers + notes: `claude-haiku-5-5`. Summary + Ask this call: `claude-sonnet-5-5`. "Best" option: `claude-opus-5-5`. One catalog, overridable in Settings |
| Key | Bring your own key, verified live in onboarding, stored in the login Keychain, never in defaults or logs |
| Structured output | Summaries use `output_config.format` with a strict JSON schema (`additionalProperties: false`). The 5.5 models reject forced `tool_choice`, and they no longer take `temperature` |
| Storage | Encrypted per-session archive + encrypted library index. SwiftData removed (the index is small and fully encrypted) |
| Audio retention | WAVs are written during capture for crash safety and deleted at seal by default |
| Legacy | Claude Code / Codex bridges, matching, repo write-back, Code Assist, Whisper and filing memory are deleted. Old sealed sessions migrate into the new library |
| Screen Privacy | Kept, renamed, default off, quick toggle in the live panel |

---

## 3. Architecture

### 3.1 Packages after the rebuild

```
SaaaApp/            App, island, live panel, hub (Home · Sessions · Playbooks · Settings), onboarding
Packages/
  Core/             Transcript, playbook + summary models, question detection, redaction, privacy policy
  AnthropicKit/     SSE client, request/response types, errors, model catalog, usage + cost, Keychain
  AudioCapture/     Process taps + mic (unchanged hot path), now also a live 16 kHz sample stream
  Transcription/    LiveTranscript model, SpeechAnalyzer lanes, asset install, file transcription
  Copilot/          Prompt composer (cache-shaped), copilot engine, live notes, summaries, Ask this call
  CallSession/      Session lifecycle, hotkeys, meeting detection, finalization
  CalendarContext/  EventKit reader (current + upcoming events)
  Persistence/      Encryption, session archive, encrypted library, playbook store, export, migration
  DesignSystem/     Field Instrument palette + Liquid Glass components and motion
```

Retired: `ClaudeBridge`, `AgentBridge`, `Matching`, `Extraction`, the Whisper XCFramework.

### 3.2 Live data flow

```
 mic ─┐                                   ┌─ SpeechAnalyzer (Me)  ─┐
      ├─ CaptureSession ── 16 kHz chunks ─┤                        ├─ LiveTranscript ── CopilotEngine ──► Live panel
 app ─┘   (WAVs for crash safety)         └─ SpeechAnalyzer (Them)─┘   committed +        │   ▲
                                                                       volatile tails     ▼   │ text deltas
                                                                                  PromptComposer ─► AnthropicKit ─► api.anthropic.com
```

Echo guard: when you are on speakers, your mic hears them. Committed *Me* lines that repeat a *Them* line from the last few seconds are dropped.

### 3.3 Prompt shape (cache-first)

```
system  [rules + playbook + session context + knowledge]          ← breakpoint 1, stable for the call
user    [transcript chunk 1] … [transcript chunk k]                ← breakpoint 2, moves forward as chunks fill
        [open chunk + in-progress words + the task]                ← uncached, usually 200–600 tokens
```

Chunks hold a fixed number of settled lines (older than ~6 s, so both lanes have finalized), so their text never changes once emitted. Each request finds the previous request's breakpoint within the 20-block lookback and pays cache-read price for everything before it.

### 3.4 Latency budget for a live answer

| Stage | Budget |
|---|---|
| Spoken word → volatile text on screen | ≤ 1.0 s |
| Tap → request sent (prompt build) | ≤ 15 ms |
| Request → first token (Haiku 5.5, cached prefix) | ≤ 900 ms |
| First token on screen | ≤ 1.2 s from tap |
| Complete answer (≤ 90 words) | ≤ 2.5 s |

First-token time is measured on every request and shown on each answer card; the connection test in Settings reports the round trip. Measured on the build Mac (Oct 11): first words on screen 1.1 s after speech starts; first answer token 0.7 to 0.8 s on a warm connection, 1.2 s from a cold process.

### 3.5 Cost model (published prices, Oct 2026)

| Model | Input | Output | Cache write (5 m) | Cache read |
|---|---|---|---|---|
| Haiku 5.5 (≤100K prompt) | $0.10 | $0.50 | $0.125 | $0.01 |
| Sonnet 5.5 | $2 | $10 | $2.50 | $0.10 |
| Opus 5.5 | $4 | $20 | $5 | $0.20 |

A one-hour call with 40 live answers, 40 notes refreshes and one Sonnet summary comes to roughly **$0.05–0.10**. The ledger records real usage per request.

### 3.6 Storage and what leaves the Mac

- `~/Library/Application Support/Saaa/Sessions/<id>/session.enc`: transcript, copilot thread, notes, summary, chat, usage (AES-GCM, key in the Keychain).
- `library.enc`: titles, dates, TL;DRs for the list and search. `playbooks.enc`: your playbooks and knowledge.
- Leaves the Mac: (1) requests to `api.anthropic.com` when the copilot, notes, summary or chat runs; (2) Apple's speech assets, downloaded by the system. Nothing else. No telemetry. Under Anthropic's policy, API inputs and outputs are deleted within 30 days by default.

---

## 4. Phases

Each phase ends with: package tests green, the app building, and a commit on `rebuild/live-copilot`.

### P0 · The live core

**Phase 1: AnthropicKit**
- SSE parser (pure, byte-split safe), typed stream events, `URLSession.bytes` transport behind a protocol, cancellation and timeouts.
- Request types with `cache_control`, JSON-schema structured output, deterministic key order (unordered JSON breaks caching).
- Errors: auth, permission, rate limit (Retry-After), overloaded, request too large, server, network, malformed, timeout, mid-stream `error` events.
- Model catalog + roles, usage accounting (`cache_read`, `cache_creation` 5 m / 1 h) and cost; Keychain key store; key verifier.
- **Done when:** unit tests cover parsing, encoding, errors and costs; the live test streams a real Haiku 5.5 answer, cancels a stream mid-flight, and sees a cache read on the second call.

**Phase 2: Live transcription**
- `LiveAudioStream` from the capture drain (mute and rebuild gaps respected).
- One `SpeechAnalyzer` lane per side, converter to the analyzer's best format, volatile/final handling, vocabulary context.
- `LiveTranscript`: committed segments + volatile tails per lane, merged timeline, echo guard, settled-chunk API.
- Speech asset check/install with progress; file transcription for imports.
- **Done when:** unit tests cover merge, volatile replacement, echo guard and chunk stability; the self-test transcribes synthesized speech end to end on the Mac.

**Phase 3: Copilot engine**
- `PromptComposer` for answer / say / ask / catch-up / custom / free ask / notes / summary / chat.
- `CopilotEngine`: streaming answer state, thread, pins, cancel-and-replace, auto-suggest on detected questions (cooldown), live notes every ~90 s while people are talking, usage ledger.
- **Done when:** composer and engine tests pass against a mock stream; a real call answers in under 2 s.

### P1 · The experience

**Phase 4: Playbooks and prep**
- `Playbook` model, eight built-ins (General, Sales, Customer Success, Recruiting, Investor, Standup, 1:1, Lecture), encrypted store, duplicate and edit.
- Knowledge files (text, Markdown, PDF via PDFKit) folded into the cached prefix.
- Prep sheet; calendar pre-fill; title rules pick the playbook; meeting detection on the island.
- **Done when:** switching Sales ↔ Recruiting visibly changes quick actions, answers and the summary sections.

**Phase 5: Liquid Glass**
- DesignSystem: glass card, toolbar, action chip, key cap, streaming text, talk-ratio bar; Reduce Transparency switches glass to opaque surfaces.
- Island: black compact bar (unchanged contracts) + glass live panel below the menu bar line (no alpha at menu-bar height).
- Hub: Home (up next, recent, start), Sessions (search, detail), Playbooks (grid + editor), Settings.
- **Done when:** light, dark, increased contrast and Reduce Transparency all read correctly; no glass on glass.

**Phase 6: Onboarding**
- Welcome + honest data flow → permissions (mic, system audio with guided grant + verify, calendar) → connect Claude (paste key, live verify with latency) → speech assets → default playbook → island hello. Every step re-runnable from Settings.
- **Done when:** a clean user account reaches "ready" without a terminal and without a stuck step.

**Phase 7: Screen Privacy and consent**
- `ScreenPrivacy` (all windows / content windows), quick toggle and badge in the panel; disclosure helper with copy-to-clipboard.
- **Done when:** the toggle hides and shows Saaa in a real screen share with the indicator visible.

### P2 · After the call, and ship

**Phase 8: Summary, Ask this call, library**
- Summary via JSON-schema structured output (Sonnet 5.5), seeded with live notes; follow-up email; playbook sections.
- Session detail: summary document, copilot thread, transcript with search, Ask this call (streaming, cached transcript).
- Export Markdown / HTML (redaction option), copy, save to a folder you pick once.
- **Done when:** a finished call yields a correct summary within ~10 s of stopping.

**Phase 9: Retire, migrate, document, release**
- Delete legacy packages and files; migrate old `session.enc` archives and the old Live Assist prompt into the new library and a custom playbook.
- Rewrite README, AI_POLICY, SECURITY, ARCHITECTURE for the new data flow.
- Release through the existing notarized DMG script.
- **Done when:** clean build, all package tests green, deployed app passes the smoke run.

---

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Two concurrent `SpeechAnalyzer` sessions hit a resource limit | Each lane retries once (on macOS 27 with `ignoresResourceLimits`); if Me still fails, Them stays live and the panel says the Me transcript is paused while recording continues |
| Locale not covered by SpeechTranscriber | `DictationTranscriber` for the locale; Settings lists supported languages |
| Echo on speakers garbles the Me lane | `EchoGate` silences mic frames that carry only the other side (frame energy against a learned speaker-to-mic coupling) before recognition; the text echo guard drops exact repeats; the panel suggests headphones once filtering is active |
| API outage, rate limit, offline | Quiet inline notice, retry with backoff for summaries, live answers never block capture |
| Transcript leaves the device | Stated in onboarding, Settings and docs; nothing is sent until the copilot runs; per-session usage visible |
| Glass legibility over busy backgrounds | Glass only for chrome; reading surfaces are plain; Reduce Transparency respected |
| Cache misses inflate cost | Deterministic encoding, settled chunks, usage ledger shows cache-read ratio |

---

## 6. Retired

| Removed | Replaced by |
|---|---|
| `ClaudeBridge`, `AgentBridge` (claude/codex subprocesses) | `AnthropicKit` |
| `Matching`, `Extraction`, `FilingMemory`, Review window | Summary + save to folder |
| Whisper XCFramework, `ModelManager`, windowed live loop | `SpeechAnalyzer` lanes |
| SwiftData `SessionStore` | Encrypted `SessionLibrary` |
| Prompts pane (vocabulary / filing / live assist) | Playbooks (vocabulary + instructions per playbook) |
| Code Assist | Out of scope for a meeting copilot |

## 7. Status

| Phase | State | Commit |
|---|---|---|
| 1 AnthropicKit | done | `9bc4814` |
| 2 Live transcription | done | `70241dc` |
| 3 Copilot engine | done | `11a031b` |
| 4 Playbooks and prep | done | `11a031b`, `8568bca` |
| 5 Liquid Glass | done | `8568bca` |
| 6 Onboarding | done | `8568bca`, `d2d2838` |
| 7 Screen Privacy | done in code; confirm in a real screen share | `8568bca` |
| 8 Summary and library | done | `8568bca`, `d2d2838` |
| 9 Retire, migrate, document, release | done; v0.9.0 is the first release of the rebuild | this commit |

**Verification so far**

- 183 tests in 9 packages pass (`swift test` in each), including the echo gate and the speech integration tests on the device.
- Live Claude tests (opt-in, real key): streaming, cache read on the second call, cancellation, structured output, key verification.
- In-app self-tests on the build Mac: `--selftest-transcribe` (first partial 1.09 s, correct text), `--selftest-pipeline` (synthesized question, live transcript, question detected, streamed Haiku answer grounded in the playbook's knowledge, first token 1.19 s from a cold process).
- A real session recorded, transcribed, summarized and reopened in the hub.

**Still to check by hand**: Screen Privacy in a live screen share, the echo gate on laptop speakers in a real call, and the first-run flow on a clean user account.
