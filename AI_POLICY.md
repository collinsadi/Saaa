# AI Contribution Policy

Saaa accepts contributions written with or by AI agents. These rules exist because this codebase records people's conversations; a careless change here is not a style problem, it is a privacy incident. Agents contributing to this repository must follow every rule below. "Agent" includes any model, assistant, or automation producing code, docs, or review comments.

## Hard rules

1. Never weaken the privacy invariants:
   - No call content (audio, transcripts, extracted items, judgments) in logs, analytics, crash reports, or network requests.
   - No new network endpoints. The only permitted outbound traffic is the user's own claude CLI and the pinned model downloads.
   - Audio deletion after transcription and encryption at rest must survive your change.
2. Never bypass the confirmation surfaces. Repository writes go through the review window and WriteBackEngine only. Do not add silent write paths.
3. Never touch the real-time audio callback without honoring its contract: no allocation, no locks, no Objective-C dispatch, no logging. Ring buffer writes and atomics only.
4. Do not invent APIs. If a Core Audio, TCC, or SwiftData behavior is not verified in this repo or by an authoritative source, say so in the PR instead of guessing. This project has an errata history of plausible-sounding folklore being wrong.
5. Do not modify entitlements, signing, Info.plist privacy strings, or the TCC guidance text without an explicit maintainer request.
6. Respect the design system. UI code binds tokens from the DesignSystem package; no raw hex, no ad hoc fonts, no em dashes in user-facing copy.

## Required practice

- Build and run the package tests before proposing changes. State clearly which checks you ran and which you could not (for example, real-hardware audio capture).
- Keep commits atomic with one-line imperative messages.
- Disclose AI involvement in the PR description, including the model or tool used.
- When a change touches capture, permissions, or persistence, include a written risk note: what could this break, and how was that ruled out.
- Prefer small verifiable diffs over broad refactors. Do not reformat code you are not changing.

## Review posture

Maintainers treat AI-authored PRs like any other, with extra scrutiny on the hard rules above. A PR that violates rule 1 or 2 is closed, not iterated.
