# Saaa relay

A small Go server that lets Saaa use Claude without keeping an API key on the Mac.

You bring your own Anthropic key. When you connect it, the relay checks it with Anthropic, encrypts it with AES-256-GCM under a server master key, and stores it. Each device gets a random access token, and the server keeps only that token's SHA-256 hash. Requests stream through to `api.anthropic.com` byte for byte, flushed as they arrive. The relay never logs or stores prompts, transcripts, answers, keys or tokens. It logs one line per request: method, path, status, timing and a short account id. It also counts each account's tokens and cost per month, read from the usage numbers in Anthropic's replies after each chunk has gone out, so Settings can show usage and hosted accounts can have an allowance. Those counts are numbers only.

The server can also offer **hosted accounts** (a beta, off by default): someone with an invite code uses the server operator's Anthropic key instead of their own, within a monthly allowance.

No dependencies beyond the Go standard library.

## API

Every route except `/v1/register` and `/healthz` takes `Authorization: Bearer <token>`. Errors use Anthropic's shape: `{"type":"error","error":{"type":...,"message":...}}`.

| Route | Does |
|---|---|
| `POST /v1/register` | `{"api_key","label"}` verifies the key with Anthropic, stores it sealed and returns `{"token","account","joined_existing","verified_ms"}`. A device that connects with a key that's already stored joins that account. |
| `POST /v1/messages` | Relayed to Anthropic with the account's key, streaming included. |
| `POST /v1/messages/count_tokens` | Relayed. |
| `GET /v1/models` | Relayed. The app uses it to warm the connection. |
| `GET /v1/account` | Returns the kind (`byok` or `hosted`), plan, key hint (`sk-ant-…abcd`), device count and dates. |
| `GET /v1/usage` | This month's requests, tokens and cost for the account; for a hosted account also `budget_usd`, `remaining_usd` and `resets_at`. |
| `POST /v1/hosted/join` | `{"invite_code","label"}` opens a hosted account, or `{"link_code","label"}` adds this Mac to one. Returns the same shape as `/v1/register`. Only when hosted accounts are on. |
| `POST /v1/account/link` | For a hosted account: a one-time code, good for ten minutes, that another Mac enters to join it. |
| `PUT /v1/account/key` | Replaces the key; it's verified first. |
| `DELETE /v1/token` | Signs this device out. |
| `DELETE /v1/account` | Deletes the account, its sealed key and every device token. |
| `GET /healthz` | Returns `ok`. |

Limits: 240 requests per minute per account, 20 registrations per hour per address, and 8 MB per request body. All of these can be changed.

Hosted accounts are checked before anything reaches Anthropic: past the month's allowance a request gets `402` with `{"type":"error","error":{"type":"quota_exceeded",...}}`, and a model outside `SAAA_HOSTED_MODELS` gets `403`. Bring-your-own-key accounts have no allowance; their usage is only counted.

## Configuration

Settings come from environment variables; see [`deploy/relay.env.example`](deploy/relay.env.example).

| Variable | Default | Meaning |
|---|---|---|
| `SAAA_ADDR` | `:8443` | Listen address |
| `SAAA_DATA` | `./data` | Holds `master.key` (32 random bytes, created on first start) and `accounts.json`, both mode 0600 |
| `SAAA_TLS_CERT`, `SAAA_TLS_KEY` | | Serve HTTPS directly instead of behind a proxy |
| `SAAA_TRUST_PROXY` | | Set to `1` behind a proxy that sets `X-Forwarded-For` |
| `SAAA_RATE_PER_MINUTE` | `240` | Requests per account per minute |
| `SAAA_MAX_BODY_MB` | `8` | Largest request body |
| `SAAA_REGISTRATION_CODE` | | If set, connecting a key requires this invitation code |
| `SAAA_HOSTED` | | Set to `1` to offer hosted accounts to people with an invite |
| `SAAA_HOSTED_KEY_FILE` | | File holding the Anthropic key hosted accounts use (keep it `0640 root:saaa`); required with `SAAA_HOSTED=1` |
| `SAAA_HOSTED_BUDGET_USD` | `5` | Monthly allowance per hosted account, unless its invite set one |
| `SAAA_HOSTED_MODELS` | Haiku 5.5, Sonnet 5.5 | Comma-separated model ids hosted accounts may use |

Back up `data/master.key`. Without it, the stored keys can't be decrypted and every device has to connect again. The data directory also holds `usage.json` (monthly counts) and, once you make invites, `invites.json` (only each code's hash), both mode 0600.

## Invites

Make an invite as the user the relay runs as, so the server can read the file:

```sh
sudo -u saaa env SAAA_DATA=/collins/saa/data /collins/saa/bin/saaa-relay invite -plan beta -uses 1 -days 30 -note "Dana"
```

It prints a code like `SAAA-7K2M-Q9XD`, the only time the code exists in plain text. `-budget 10` gives that invite's accounts a $10 monthly allowance instead of the default. The running server picks new invites up without a restart.

## Deploy

`deploy/install.sh <host>` runs as root on Ubuntu from a checkout in `/collins/saa/repo`. It does the following:

1. Installs Go (official release, checksum verified).
2. Creates a `saaa` system user.
3. Runs the tests and builds the relay into `/collins/saa/bin`.
4. Installs the hardened `saaa-relay` systemd unit, listening on `127.0.0.1:8787`.
5. Adds a validated Caddy site for `<host>`. Caddy obtains the TLS certificate automatically, and other sites on the server are left untouched.

Running it again updates in place.

```sh
cd Server && go test ./...   # tests use a fake Anthropic; no key needed
```
