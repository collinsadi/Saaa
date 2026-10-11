# AI Contribution Policy

Saaa accepts contributions written with or by AI agents. These rules exist because this codebase listens to people's conversations; a careless change here is not a style problem, it is a privacy incident. Agents contributing to this repository must follow every rule below. "Agent" includes any model, assistant, or automation producing code, docs, or review comments.

## Hard rules

1. Never weaken the privacy invariants:
   - No call content (audio, transcripts, screen text, copilot answers, notes, summaries, prep notes, knowledge files) in logs, analytics, crash reports, or any network request other than the documented Claude requests.
   - The only permitted outbound traffic is the Saaa relay, which forwards to the Anthropic Messages API with the user's own key, when the user acts or an enabled copilot feature runs, plus Apple's speech asset downloads handled by macOS. No new endpoints, no telemetry, no update pings. The relay never logs or stores request or response content.
   - Audio never leaves the Mac. Encryption at rest must survive your change, and keeping audio stays an explicit opt-in.
   - Screen content leaves the Mac as text, except one picture of one window per press of Send image, which stays off until the user turns it on in Settings; that picture is scaled down, has every recognized line the redactor would mask blacked out first, is held in memory only and is never written to disk. Text leaves only after on-device redaction (`SecretRedactor`), and only when the user presses Look or when Watch, which the user turned on, sees a new error in an app the user picked. Watch stays off by default, reads only the chosen apps and pauses during calls. Editor extensions reach Saaa only through the local editor socket (owner-only, same-user peers), answer only when Saaa asks at a Look or a Watch read, and their text goes through the same redaction. Apart from a Send image picture, screenshots never leave the capture call, and no screenshot is ever written to disk. Screen text and Code Assist hints are held in memory for What was sent and are never sealed with a session or written to disk.
   - Ask all calls and the prep brief search sessions on the Mac and send only the excerpts the search picked, only when the user asks. Never send whole libraries or build a server-side index of calls.
   - The API key never lives on the Mac. On the relay it is stored only sealed (AES-256-GCM under the server master key), and device tokens are stored only as hashes. Keys and tokens never appear in logs, exports, or error messages.
2. Never record without the user starting it. Meeting detection may suggest a session; only the user starts one. The visible recording indicator and the consent reminder stay.
3. Screen Privacy stays a standing, user-controlled setting, off by default. Never tie it to detecting a capture or screen share, and never build features meant to conceal Saaa from the other people on a call. No candidate-side interview or exam modes. Look and later screen features serve the user's own work, practice, and interviewer-side calls: while a session records, a coding problem on screen gets the approach, never solution code. Code Assist stops at the approach the same way while a session records and on pages that look like a hiring assessment, an exam or a proctored test (`AssessmentGuard`); only add markers to that guard, never remove them. These features are never marketed or tuned for interviews or exams the user is taking.
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
