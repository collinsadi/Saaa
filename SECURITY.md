# Security Policy

Saaa listens to private conversations, so security reports are taken seriously and handled quickly.

## Reporting

Email collinsadi20@gmail.com with the details. Please do not open public issues for vulnerabilities. You will get an acknowledgment within 72 hours.

## Scope

Reports of particular interest:

- Anything that lets call content (audio, transcripts, answers, notes, summaries) leave the machine outside the documented flow, which is requests through the Saaa relay to the Anthropic Messages API, or land on disk unencrypted outside the documented paths (kept audio is opt-in).
- The relay (`Server/`): recovering a stored API key without the master key, using another account's key, forging or replaying device tokens, getting the relay to call anything other than its configured Anthropic upstream, or content ending up in its logs or data files.
- Exposure of the Claude API key or a device token: logs, exports, crash reports, or requests to any host other than the configured relay.
- Weaknesses in the AES-GCM sealing, the content key file, or the session library index.
- Prompt injection through transcripts, prep notes, or knowledge files that causes anything beyond text in the copilot panel. The copilot has no tools and takes no actions; report anything that changes that.
- Recording that starts without the user, or bypasses of the visible recording indicator.
- Screen Privacy failing open: a Saaa window appearing in a capture while the setting says it is hidden.

## Out of scope

- Issues requiring physical access to an unlocked machine.
- The user granting permissions to other software.
- How Anthropic handles API data once received; see Anthropic's own policies and report issues there.
