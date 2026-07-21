# Contributing to Saaa

Thanks for helping. Saaa is a native macOS app with a strict privacy posture; contributions are held to that bar.

## Setup

1. Apple Silicon Mac, macOS 15 or newer, Xcode 16.4 or newer.
2. Clone and build:

   ```sh
   xcodebuild -project Saaa.xcodeproj -scheme Saaa -configuration Debug build
   ```

3. Run package tests before and after your change:

   ```sh
   for p in Packages/*/; do (cd "$p" && swift test); done
   ```

4. Audio capture behavior can only be fully verified on real hardware from a user-launched app at a stable path (copy to Applications and launch it yourself). Capture checks run from shells or scripts report false negatives because macOS misattributes the permission.

## Ground rules

- Swift 6 with strict concurrency. No data-race suppressions without a comment explaining why they are safe.
- The real-time audio callback stays lock-free and allocation-free. Ring buffer writes and atomics only.
- Tokens first in UI code. No raw hex colors, no magic numbers; bind to the DesignSystem package.
- Privacy is not negotiable: never log call content, never add telemetry, never write to a repository outside the confirmed write-back path, never weaken the visible recording indicator.
- Every subsystem keeps a defined fallback. Do not introduce dead ends.
- No em dashes in user-facing copy. Short messages over long ones.

## Commits and pull requests

- One logical change per commit, one-line imperative message ("Add x", "Fix y"). No trailing periods, no em dashes.
- PRs describe what changed, why, and how it was tested. Include hardware test notes for anything touching AudioCapture.
- New code paths need tests where the logic is testable off-hardware (state machines, routing, parsing, scoring).
- UI changes should include a screenshot in light and dark mode.

## Where things live

Ten local Swift packages behind the app target. AudioCapture (capture engine), CallSession (lifecycle and orchestration), Transcription (whisper.cpp bridge), CalendarContext, Matching (prefilter), ClaudeBridge (claude subprocess), Extraction (write-back), Persistence (store and crypto), DesignSystem (tokens and components), Core (shared models).

## AI-assisted contributions

Welcome, with conditions. Read [AI_POLICY.md](AI_POLICY.md) before opening a PR that was written wholly or partly by an AI agent.
