# AI Contribution Policy

Saaa accepts contributions written with or by AI agents. These rules exist because this codebase listens to people's conversations; a careless change here is not a style problem, it is a privacy incident. Agents contributing to this repository must follow every rule below. "Agent" includes any model, assistant, or automation producing code, docs, or review comments.

## Hard rules

1. Never weaken the privacy invariants:
   - No call content (audio, transcripts, copilot answers, notes, summaries, prep notes, knowledge files) in logs, analytics, crash reports, or any network request other than the documented Claude requests.
   - The only permitted outbound traffic is the Anthropic Messages API, called with the user's own key when the user acts or an enabled copilot feature runs, plus Apple's speech asset downloads handled by macOS. No new endpoints, no telemetry, no update pings.
   - Audio never leaves the Mac. Encryption at rest must survive your change, and keeping audio stays an explicit opt-in.
   - The API key lives only in the Keychain: never in defaults, files, logs, exports, or error messages.
2. Never record without the user starting it. Meeting detection may suggest a session; only the user starts one. The visible recording indicator and the consent reminder stay.
3. Screen Privacy stays a standing, user-controlled setting, off by default. Never tie it to detecting a capture or screen share, and never build features meant to conceal Saaa from the other people on a call. No candidate-side interview or exam modes.
4. Never touch the real-time audio callback without honoring its contract: no allocation, no locks, no Objective-C dispatch, no logging. Ring buffer writes and atomics only.
5. Do not invent APIs. If a Core Audio, TCC, SpeechAnalyzer, Liquid Glass, or Anthropic API behavior is not verified in this repo or by an authoritative source, say so in the PR instead of guessing. This project has an errata history of plausible-sounding folklore being wrong.
6. Do not modify entitlements, signing, Info.plist privacy strings, or the permission guidance text without an explicit maintainer request.
7. Respect the design system. UI code binds tokens from the DesignSystem package; no raw hex, no ad hoc fonts, no em dashes in user-facing copy.

## Required practice

- Build and run the package tests before proposing changes. State clearly which checks you ran and which you could not (for example, real-hardware audio capture or the live Claude tests).
- Prompt changes keep the cache shape intact: deterministic request encoding, a stable system block, transcript chunks that never change once sent. Run the Copilot tests, and the opt-in live API tests when you touch AnthropicKit or the prompt composer.
- Keep commits atomic with one-line imperative messages.
- Disclose AI involvement in the PR description, including the model or tool used.
- When a change touches capture, permissions, persistence, or what is sent to Claude, include a written risk note: what could this break, and how was that ruled out.
- Prefer small verifiable diffs over broad refactors. Do not reformat code you are not changing.

## Review posture

Maintainers treat AI-authored PRs like any other, with extra scrutiny on the hard rules above. A PR that violates rule 1, 2 or 3 is closed, not iterated.
