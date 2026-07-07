#!/usr/bin/env bash
set -euo pipefail

# runmod-finn-ios-live.sh
#
# "runmod" = a RUNTIME MODIFICATION of a LIVE, already-running finn sandbox
# (vs setup-finn.sh, which onboards the sandbox and wires search/fetch/Telegram).
# It mutates the running gateway's config + policy in place and does NOT rebuild
# the image — so it must be re-applied after a full rebuild/re-onboard.
# Standalone optional add-on: run it AFTER ./setup-finn.sh; not invoked by it.
#
# Publishes finn's gateway to the OpenClaw iOS app over TAILSCALE SERVE.
#
# Topology (why this path): the gateway runs INSIDE the sandbox, bound to
# loopback in its own netns — a phone can never reach it directly. But the host
# side already carries a bridge: openshell's ssh-proxy forwards host
# 127.0.0.1:18789 → sandbox gateway 18789. Tailscale Serve publishes that
# loopback forward as https://<mac>.<tailnet>.ts.net with a tailnet-only TLS
# cert, so the phone reaches finn from anywhere on the tailnet and nothing is
# exposed to the LAN. Docs: https://docs.openclaw.ai/platforms/ios
#
# NOTE: Bonjour discovery in the iOS app will NEVER find this gateway — the
# gateway netns has mDNS disabled (the `[guard] os.networkInterfaces()` lines
# in /tmp/gateway.log). Pairing is by QR / setup code / manual host only.
#
# PREREQUISITES (one-time, interactive):
#   1. Tailscale installed + logged in on the Mac (brew install --cask tailscale-app)
#      and on the iPhone (App Store), same tailnet.
#   2. MagicDNS + HTTPS Certificates enabled for the tailnet
#      (https://login.tailscale.com/admin/dns) — Serve needs both.
#
# Usage:
#   ./runmod-finn-ios-live.sh                 # serve + origin patch + restart
#   IOS_PUSH=1 ./runmod-finn-ios-live.sh      # …also allow the APNs push relay egress
#   TS_URL=https://mac.tailnet.ts.net ./runmod-finn-ios-live.sh   # skip CLI detection

SANDBOX="${SANDBOX:-finn}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GW_PORT="${GW_PORT:-18789}"
PRESET="ios-push"
PRESETS_DIR="${PRESETS_DIR:-$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets}"
case "${IOS_PUSH:-0}" in 1|true|yes|on|TRUE|YES|ON) PUSH_ON=1 ;; *) PUSH_ON=0 ;; esac

CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
[ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (is $SANDBOX up? run ./setup-finn.sh first)." >&2; exit 1; }
echo "==> Container:  $CONTAINER"

# --- 1. Resolve the tailscale CLI + the tailnet HTTPS URL --------------------
TS_BIN=""
for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  command -v "$c" >/dev/null 2>&1 && { TS_BIN="$c"; break; }
done
if [ -z "${TS_URL:-}" ]; then
  [ -n "$TS_BIN" ] || { echo "ERROR: tailscale CLI not found and TS_URL not set. Install Tailscale (brew install --cask tailscale-app), log in, or pass TS_URL=https://<mac>.<tailnet>.ts.net" >&2; exit 1; }
  DNSNAME="$("$TS_BIN" status --json 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
  [ -n "$DNSNAME" ] || { echo "ERROR: could not read this machine's tailnet DNS name — is Tailscale logged in?" >&2; exit 1; }
  TS_URL="https://$DNSNAME"
fi
echo "==> Tailnet URL: $TS_URL"

# --- 2. Publish the loopback gateway forward over Tailscale Serve ------------
# Idempotent: re-running serve for the same target is a no-op/refresh.
if [ -n "$TS_BIN" ]; then
  echo "==> tailscale serve 443 -> 127.0.0.1:$GW_PORT ..."
  "$TS_BIN" serve --bg "$GW_PORT" \
    || { echo "ERROR: tailscale serve failed — check 'tailscale serve status'; HTTPS certs enabled for the tailnet?" >&2; exit 1; }
  "$TS_BIN" serve status 2>/dev/null | sed 's/^/    /' || true
else
  echo "==> NOTE: no tailscale CLI here; assuming Serve for $TS_URL -> 127.0.0.1:$GW_PORT is already configured."
fi

# --- 3. Allow the tailnet origin on the gateway Control UI -------------------
# allowedOrigins is pinned to http://127.0.0.1:18789; add the tailnet origin so
# the Control UI (and any browser-origin WS) also works from tailnet devices.
# The native iOS app itself sends no browser Origin — this is for completeness,
# not the app's connection path. Idempotent JSON edit as the sandbox user.
echo "==> Adding $TS_URL to gateway.controlUi.allowedOrigins (idempotent) ..."
docker exec -u 998 -e HOME=/sandbox -e TS_URL="$TS_URL" "$CONTAINER" python3 - <<'PY'
import json, os
p = "/sandbox/.openclaw/openclaw.json"
cfg = json.load(open(p))
origins = cfg.setdefault("gateway", {}).setdefault("controlUi", {}).setdefault("allowedOrigins", [])
url = os.environ["TS_URL"].rstrip("/")
if url in origins:
    print(f"    already present: {url}")
else:
    origins.append(url)
    json.dump(cfg, open(p, "w"), indent=2)
    print(f"    added: {url}")
PY

# --- 4. Optional: egress for background wake pushes (APNs relay) -------------
# Official App Store iOS builds register through OpenClaw's hosted relay; the
# GATEWAY calls ios-push-relay.openclaw.ai for push.test / reconnect wakes.
# Without this, everything still works foregrounded — only background wakes are lost.
if [ "$PUSH_ON" = 1 ]; then
  if [ -d "$PRESETS_DIR" ]; then
    cp "$HERE/fixes/$PRESET.yaml" "$PRESETS_DIR/"
    echo "==> Copied fixes/$PRESET.yaml into the blueprint."
  else
    echo "WARNING: presets dir not found ($PRESETS_DIR); set PRESETS_DIR. Trying policy-add anyway." >&2
  fi
  echo "==> Applying '$PRESET' network policy ..."
  nemoclaw "$SANDBOX" policy-add "$PRESET" --yes \
    || echo "    (policy-add non-zero — may already be applied; check: nemoclaw $SANDBOX policy-list)"
else
  echo "==> Skipping APNs push-relay egress (background wakes off). Enable with: IOS_PUSH=1 $0"
fi

# --- 5. Restart the gateway worker so the config change is live --------------
# NEVER `docker restart` (CLAUDE.md hard rule); TERM the openclaw child of
# nemoclaw-start and let the supervisor relaunch it. Log-authoritative verify.
echo "==> Restarting the gateway worker ..."
GLOG="/tmp/gateway.log"
before="$(docker exec -u 0 "$CONTAINER" sh -c "wc -l < $GLOG 2>/dev/null" | tr -d '[:space:]')"
GWPID="$(docker exec -u 0 "$CONTAINER" sh -c '
  for p in $(pgrep -x openclaw 2>/dev/null); do
    pp=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
    tr "\0" " " < /proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }
  done' 2>/dev/null | head -1)"
if [ -n "$GWPID" ]; then
  docker exec -u 0 "$CONTAINER" sh -c "kill -TERM $GWPID" \
    && echo "    Sent TERM to the gateway worker (pid $GWPID); supervisor relaunching ..."
else
  echo "    NOTE: gateway worker not found by name+parent; falling back to nemoclaw recover."
  nemoclaw "$SANDBOX" recover >/dev/null 2>&1 || true
fi
ok=""
for _ in 1 2 3 4 5 6 7 8; do
  if docker exec -u 0 "$CONTAINER" sh -c "tail -n +$(( ${before:-0} + 1 )) $GLOG 2>/dev/null" \
       | grep -qiE "http server listening|\[gateway\] ready"; then ok=1; break; fi
  sleep 5
done
[ -n "$ok" ] && echo "    Gateway restarted cleanly (fresh 'listening'/'ready' in $GLOG)." \
             || echo "    NOTE: no fresh restart line yet — check $GLOG before pairing."

# --- 6. Pairing steps (interactive, on the Mac + the phone) ------------------
cat <<EOF

==> Done. Pair the phone:
   1. iPhone: install Tailscale (log into the same tailnet) + the OpenClaw app.
   2. Mac browser: open the Control UI  http://127.0.0.1:$GW_PORT  -> Nodes ->
      Devices card -> "Pair mobile device" (QR).
   3. iOS app: Settings -> Gateway -> scan the QR (or paste the setup code).
      Bonjour discovery will NOT list this gateway (mDNS is disabled in the
      gateway netns) — if the QR route fails, use Manual Host:
      host $(echo "$TS_URL" | sed 's|https://||')  port 443.
   4. If a pairing request sits pending, approve it from the gateway:
        docker exec -u 0 $CONTAINER /sandbox/.cache/radar/gw-cron.sh devices list
        docker exec -u 0 $CONTAINER /sandbox/.cache/radar/gw-cron.sh devices approve <requestId>
   5. Verify:
        docker exec -u 0 $CONTAINER /sandbox/.cache/radar/gw-cron.sh nodes status
EOF
