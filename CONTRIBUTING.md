# Contributing to Saaa

Thanks for helping. Saaa is a native macOS app with a strict privacy posture; contributions are held to that bar.

## Setup

1. Apple silicon Mac, macOS 26 or newer, Xcode 27 or newer.
2. Clone and build:

   ```sh
   xcodebuild -project Saaa.xcodeproj -scheme Saaa -configuration Debug build
   ```

3. Run package tests before and after your change:

   ```sh
   for p in Packages/*/; do (cd "$p" && swift test); done
   ```

4. The Claude integration tests are opt-in and use your own key:

   ```sh
   cd Packages/AnthropicKit && SAAA_LIVE_API=1 ANTHROPIC_API_KEY=... swift test --filter Live
   ```

5. Audio capture behavior can only be fully verified on real hardware from a user-launched app at a stable path (copy to Applications and launch it yourself). Capture checks run from shells or scripts can report false negatives because macOS attributes the permission to the terminal.

6. The app has headless self-tests that run inside its own process and write a report: `Saaa --selftest-transcribe <dir>` (synthesized speech through the live transcriber), `--selftest-pipeline <dir>` (speech to transcript to a streamed Claude answer, needs a key in the Keychain) and `--selftest-capture <dir>` (four seconds through the live audio stream).

## Ground rules

- Swift 6 with strict concurrency. No data-race suppressions without a comment explaining why they are safe.
- The real-time audio callback stays lock-free and allocation-free. Ring buffer writes and atomics only.
- Tokens first in UI code. No raw hex colors, no magic numbers; bind to the DesignSystem package. Glass is for chrome; text you read sits on solid surfaces.
- Privacy is not negotiable: never log call content, never add telemetry or endpoints, never record without the user starting it, never weaken the visible recording indicator.
- The copilot never blocks the recording. Every API or transcription failure degrades to a quiet notice while capture keeps running.
- Every subsystem keeps a defined fallback. Do not introduce dead ends.
- No em dashes in user-facing copy. Short messages over long ones.

## Commits and pull requests

- One logical change per commit, one-line imperative message ("Add x", "Fix y"). No trailing periods, no em dashes.
- PRs describe what changed, why, and how it was tested. Include hardware test notes for anything touching AudioCapture or Transcription.
- New code paths need tests where the logic is testable off-hardware (state machines, prompt shape, parsing, scoring).
- UI changes should include a screenshot in light and dark mode.

## Where things live

Nine local Swift packages behind the app target: Core (shared models and policies), AnthropicKit (Claude client and Keychain key), AudioCapture (capture engine), Transcription (SpeechAnalyzer lanes and the live transcript), Copilot (prompts, live answers, notes, summaries, Ask this call), CallSession (lifecycle, hotkeys, meeting detection), CalendarContext (EventKit), Persistence (sealing, library, playbooks, export) and DesignSystem (tokens, glass and components). The app target holds the island, live panel, hub, prep sheet and onboarding.

## AI-assisted contributions

Welcome, with conditions. Read [AI_POLICY.md](AI_POLICY.md) before opening a PR that was written wholly or partly by an AI agent.
