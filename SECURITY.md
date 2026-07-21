# Security Policy

Saaa records private conversations, so security reports are taken seriously and handled quickly.

## Reporting

Email collinsadi20@gmail.com with the details. Please do not open public issues for vulnerabilities. You will get an acknowledgment within 72 hours.

## Scope

Reports of particular interest:

- Anything that lets call content (audio, transcripts, extractions) leave the machine or land on disk unencrypted outside the documented paths.
- Weaknesses in the AES-GCM sealing, the Keychain key handling, or the retention flow.
- Escapes from the claude subprocess guardrails (tool allowlist, permission mode, turn caps, timeouts).
- Ways to trigger repository writes outside the confirmed write-back path, including path traversal in suggested file targets.
- Bypasses of the visible recording indicator.

## Out of scope

- Issues requiring physical access to an unlocked machine.
- The user granting permissions to other software.
