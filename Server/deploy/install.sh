#!/bin/bash
# Installs or updates the Saaa relay on this server (idempotent).
# Run as root from the repo checkout:  Server/deploy/install.sh <public-host>
#
# Layout:  /collins/saa/repo   git checkout (main)
#          /collins/saa/bin    the built relay
#          /collins/saa/data   master.key + accounts.json (saaa:saaa, 0700)
#          /collins/saa/relay.env
set -euo pipefail

HOST="${1:?usage: install.sh <public-host>}"
ROOT=/collins/saa
REPO="$ROOT/repo"
DEPLOY="$REPO/Server/deploy"
CADDYFILE=/etc/caddy/Caddyfile
log() { printf '== %s\n' "$*"; }

# 1. Go toolchain (official release, checksum verified)
GO=/usr/local/go/bin/go
minor=$("$GO" env GOVERSION 2>/dev/null | sed -nE 's/^go1\.([0-9]+).*/\1/p' || true)
if [ -z "$minor" ] || [ "$minor" -lt 22 ]; then
  log "installing Go"
  read -r file sum < <(curl -fsSL "https://go.dev/dl/?mode=json" | python3 -c '
import json, sys
release = json.load(sys.stdin)[0]
f = next(x for x in release["files"] if x["os"] == "linux" and x["arch"] == "amd64" and x["kind"] == "archive")
print(f["filename"], f["sha256"])')
  curl -fsSL "https://go.dev/dl/$file" -o /tmp/go.tgz
  echo "$sum  /tmp/go.tgz" | sha256sum -c --quiet -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tgz
  rm -f /tmp/go.tgz
fi
log "$("$GO" version)"

# 2. Service account and folders
id saaa >/dev/null 2>&1 || useradd --system --home-dir "$ROOT" --shell /usr/sbin/nologin saaa
install -d -m 0755 "$ROOT" "$ROOT/bin"
install -d -m 0700 -o saaa -g saaa "$ROOT/data"

# 3. Test and build
cd "$REPO/Server"
"$GO" test -count=1 ./... | tail -3
"$GO" build -trimpath -ldflags "-s -w -X main.version=$(git -C "$REPO" rev-parse --short HEAD)" -o "$ROOT/bin/saaa-relay.new" .
mv -f "$ROOT/bin/saaa-relay.new" "$ROOT/bin/saaa-relay"
log "built saaa-relay $("$ROOT/bin/saaa-relay" -version)"

# 4. Config (kept across updates)
if [ ! -f "$ROOT/relay.env" ]; then
  install -m 0640 -o root -g saaa "$DEPLOY/relay.env.example" "$ROOT/relay.env"
fi

# 5. Service
install -m 0644 "$DEPLOY/saaa-relay.service" /etc/systemd/system/saaa-relay.service
systemctl daemon-reload
systemctl enable --quiet saaa-relay
systemctl restart saaa-relay
for i in $(seq 1 20); do
  curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS http://127.0.0.1:8787/healthz >/dev/null || { journalctl -u saaa-relay -n 30 --no-pager; exit 1; }
log "relay running on 127.0.0.1:8787"

# 6. Caddy site (validated before reload; other sites untouched)
sed "s/__SAAA_HOST__/$HOST/" "$DEPLOY/saaa.caddy" > /etc/caddy/saaa.caddy.new
stamp=$(date +%Y%m%d-%H%M%S)
cp "$CADDYFILE" "/etc/caddy/Caddyfile.bak-saaa-$stamp"
[ -f /etc/caddy/saaa.caddy ] && cp /etc/caddy/saaa.caddy "/etc/caddy/saaa.caddy.bak-$stamp"
mv -f /etc/caddy/saaa.caddy.new /etc/caddy/saaa.caddy
grep -qF 'import /etc/caddy/saaa.caddy' "$CADDYFILE" || printf '\nimport /etc/caddy/saaa.caddy\n' >> "$CADDYFILE"
if ! caddy validate --config "$CADDYFILE" >/tmp/saaa-caddy-validate.log 2>&1; then
  cp "/etc/caddy/Caddyfile.bak-saaa-$stamp" "$CADDYFILE"
  if [ -f "/etc/caddy/saaa.caddy.bak-$stamp" ]; then cp "/etc/caddy/saaa.caddy.bak-$stamp" /etc/caddy/saaa.caddy; else rm -f /etc/caddy/saaa.caddy; fi
  tail -5 /tmp/saaa-caddy-validate.log
  echo "Caddy config invalid; restored the previous one"
  exit 1
fi
cmp -s "$CADDYFILE" "/etc/caddy/Caddyfile.bak-saaa-$stamp" && rm -f "/etc/caddy/Caddyfile.bak-saaa-$stamp"
systemctl reload caddy
log "caddy serving https://$HOST"

# 7. Public check (the first certificate can take a few seconds)
for i in $(seq 1 45); do
  if curl -fsS --max-time 5 "https://$HOST/healthz" >/dev/null 2>&1; then
    log "https://$HOST is up"
    exit 0
  fi
  sleep 2
done
echo "https://$HOST not reachable yet; recent Caddy log:"
journalctl -u caddy -n 15 --no-pager | grep -iE "saaa|$HOST|error|certificate" | tail -10
exit 2
