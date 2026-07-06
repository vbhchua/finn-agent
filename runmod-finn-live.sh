#!/usr/bin/env bash
set -euo pipefail

# runmod-finn-live.sh
#
# "runmod" = a RUNTIME MODIFICATION of a LIVE, already-running finn sandbox
# (vs setup-finn.sh, which onboards the sandbox and wires search/fetch/Telegram).
# It mutates the running gateway's config + policy in place and does NOT rebuild
# the image — so it must be re-applied after a full rebuild/onboard.
# This is a STANDALONE optional add-on: run it AFTER ./setup-finn.sh; it is not
# invoked by setup-finn.sh.
#
# Adds Microsoft Outlook / Microsoft 365 CALENDAR access to an already-running
# finn, via a zero-dependency Microsoft Graph MCP server
# (mcp/ms-calendar-mcp.mjs). Read-only by default; create/update/delete tools are
# an explicit opt-in (MS_CALENDAR_WRITE=1). Built for a PERSONAL Microsoft account
# (live.com / outlook.com), which authenticates with a delegated OAuth refresh
# token you mint once on your laptop.
#
# This is an ADDITIVE RUNTIME capability layered on a running finn (which on
# v0.0.67 is a STOCK onboard — no custom image) — the same "re-apply after a
# rebuild" model as the Firecrawl-fetch / /etc/hosts steps in setup-finn.sh. It
# does NOT rebuild the image. The egress policy it applies (fixes/ms-calendar.yaml)
# is a tighter, DELETE-capable subset of the built-in `outlook` preset; for
# read-only you may instead just `nemoclaw finn policy-add outlook`.
#
# PREREQUISITES (one-time, on your laptop):
#   1. Register a free Entra app (no admin) + grant delegated User.Read,
#      offline_access, and either Calendars.Read (read-only) or Calendars.ReadWrite
#      (to create/update/delete). See tools/ms-graph-login.mjs header for steps.
#   2. Mint a refresh token (defaults to the ReadWrite scope):
#        node tools/ms-graph-login.mjs <CLIENT_ID>
#   3. Export the credentials, then run this script:
#        export MS_CALENDAR_CLIENT_ID='<app client id>'
#        export MS_CALENDAR_REFRESH_TOKEN='<refresh token from step 2>'
#        ./runmod-finn-live.sh                 # read-only
#        MS_CALENDAR_WRITE=1 ./runmod-finn-live.sh   # read/write (create/update/delete)
#
# Running WITHOUT the two MS_CALENDAR_* vars set still wires everything up and
# validates network egress (the `diagnostics` tool) — the calendar tools just
# stay inactive until you re-run with the credentials.

SANDBOX="${SANDBOX:-finn}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESET="ms-calendar"
SERVER_SRC="$HERE/mcp/ms-calendar-mcp.mjs"
SERVER_DST="/sandbox/mcp/ms-calendar-mcp.mjs"
ENV_FILE="/sandbox/.config/ms-calendar.env"
PRESETS_DIR="${PRESETS_DIR:-$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets}"

# Write tools (create/update/delete) are an explicit opt-in — default read-only.
#   MS_CALENDAR_WRITE=1 ./runmod-finn-live.sh
# Write mode also needs a Calendars.ReadWrite-scoped refresh token (re-mint with
# the ReadWrite scope — tools/ms-graph-login.mjs defaults to it).
case "${MS_CALENDAR_WRITE:-0}" in 1|true|yes|on|TRUE|YES|ON) WRITE_ON=1 ;; *) WRITE_ON=0 ;; esac

# Optional Graph settings (sane personal-account defaults).
MS_CALENDAR_TENANT="${MS_CALENDAR_TENANT:-consumers}"
if [ "$WRITE_ON" = 1 ]; then
  DEFAULT_SCOPE="https://graph.microsoft.com/Calendars.ReadWrite offline_access User.Read"
else
  DEFAULT_SCOPE="https://graph.microsoft.com/Calendars.Read offline_access User.Read"
fi
MS_CALENDAR_SCOPE="${MS_CALENDAR_SCOPE:-$DEFAULT_SCOPE}"
MS_CALENDAR_TZ="${MS_CALENDAR_TZ:-UTC}"

echo "==> Sandbox:     $SANDBOX"
echo "==> MCP server:  $SERVER_SRC -> $SERVER_DST"
echo "==> Mode:        $([ "$WRITE_ON" = 1 ] && echo 'READ-WRITE (create/update/delete enabled)' || echo 'read-only (set MS_CALENDAR_WRITE=1 to enable writes)')"
echo "==> Presets dir: $PRESETS_DIR"

[ -f "$SERVER_SRC" ] || { echo "ERROR: $SERVER_SRC not found." >&2; exit 1; }

CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
[ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (is finn up? run ./setup-finn.sh first)." >&2; exit 1; }
echo "==> Container:   $CONTAINER"

dx998()  { docker exec -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }       # act as the sandbox user
dx998i() { docker exec -i -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }    # ...with stdin attached (piped JSON-RPC)

# --- 1. Register + activate the least-privilege network policy --------------
# graph.microsoft.com + login.microsoftonline.com only. Copy into the blueprint,
# then activate BY NAME (--from-file would collide once registered — see docs/LEARNINGS.md §6).
if [ -d "$PRESETS_DIR" ]; then
  cp "$HERE/fixes/$PRESET.yaml" "$PRESETS_DIR/"
  echo "==> Copied fixes/$PRESET.yaml into the blueprint."
else
  echo "WARNING: presets dir not found ($PRESETS_DIR); set PRESETS_DIR. Trying policy-add anyway." >&2
fi
echo "==> Applying '$PRESET' network policy ..."
nemoclaw "$SANDBOX" policy-add "$PRESET" --yes \
  || echo "    (policy-add non-zero — may already be applied; check: nemoclaw $SANDBOX policy-list)"

# --- 2. Copy the MCP server into the sandbox (sandbox-owned, persists) -------
echo "==> Installing the MCP server into the sandbox ..."
dx998 mkdir -p /sandbox/mcp
docker cp "$SERVER_SRC" "$CONTAINER:$SERVER_DST"
docker exec -u 0 "$CONTAINER" sh -c "chown 998:998 '$SERVER_DST' && chmod 644 '$SERVER_DST'"
echo "    Installed $SERVER_DST."

# --- 3. Inject credentials (0600 env file, NOT openclaw.json) ---------------
# Keeping the refresh token in a sandbox-only 0600 file keeps it out of the
# gateway config. The MCP server reads this file by default.
if [ -n "${MS_CALENDAR_CLIENT_ID:-}" ] && [ -n "${MS_CALENDAR_REFRESH_TOKEN:-}" ]; then
  echo "==> Writing credentials to $ENV_FILE (mode 0600) ..."
  docker exec -u 998 -e HOME=/sandbox \
    -e CID="$MS_CALENDAR_CLIENT_ID" -e RT="$MS_CALENDAR_REFRESH_TOKEN" \
    -e TEN="$MS_CALENDAR_TENANT" -e SC="$MS_CALENDAR_SCOPE" -e TZ="$MS_CALENDAR_TZ" -e WR="$WRITE_ON" \
    "$CONTAINER" sh -c '
      umask 077; mkdir -p /sandbox/.config;
      {
        echo "MS_CALENDAR_CLIENT_ID=$CID";
        echo "MS_CALENDAR_REFRESH_TOKEN=$RT";
        echo "MS_CALENDAR_TENANT=$TEN";
        echo "MS_CALENDAR_SCOPE=$SC";
        echo "MS_CALENDAR_TZ=$TZ";
        echo "MS_CALENDAR_WRITE=$WR";
      } > /sandbox/.config/ms-calendar.env'
  echo "    Credentials written (client_id + refresh_token; write=$WRITE_ON)."
  CREDS=1
else
  echo "==> NOTE: MS_CALENDAR_CLIENT_ID / MS_CALENDAR_REFRESH_TOKEN not set."
  echo "    Wiring everything up anyway; calendar tools stay inactive until you mint a"
  echo "    token (node tools/ms-graph-login.mjs <CLIENT_ID>) and re-run with the vars set."
  CREDS=0
fi

# --- 3.5 Derive the egress env the MCP child needs --------------------------
# CRITICAL (proven 2026-06-23): OpenClaw SCRUBS the environment when it spawns an
# MCP server subprocess, and the gateway runs in a PROXY-ONLY network namespace —
# direct egress is blocked and the proxy does TLS interception. So a plain `fetch()`
# from the MCP child fails ("...network restrictions ... login/graph blocked"), even
# though `mcp probe`/`diagnostics` (which run in the open MAIN netns) succeed and
# mislead you. Fix = re-supply the gateway's own egress env to the child: an
# HTTPS_PROXY (node honours it via NODE_USE_ENV_PROXY=1) + the proxy's CA bundle
# (NODE_EXTRA_CA_CERTS). Pull the exact values from the gateway's env; fall back to
# the NemoClaw/OpenShell defaults for this topology.
echo "==> Deriving the proxy + CA env the MCP child needs (OpenClaw scrubs it) ..."
GWENV="$(docker exec -u 0 "$CONTAINER" sh -c '
  for p in $(pgrep -x openclaw 2>/dev/null); do
    if tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -q "^NODE_EXTRA_CA_CERTS="; then
      tr "\0" "\n" < /proc/$p/environ 2>/dev/null; break
    fi
  done' 2>/dev/null)"
PROXY_URL="$(printf '%s\n' "$GWENV" | sed -n 's/^HTTPS_PROXY=//p' | head -1)";        PROXY_URL="${PROXY_URL:-http://10.200.0.1:3128}"
CA_PATH="$(printf '%s\n' "$GWENV"  | sed -n 's/^NODE_EXTRA_CA_CERTS=//p' | head -1)";  CA_PATH="${CA_PATH:-/etc/openshell-tls/openshell-ca.pem}"
NOPROXY="$(printf '%s\n' "$GWENV"  | sed -n 's/^NO_PROXY=//p' | head -1)";             NOPROXY="${NOPROXY:-localhost,127.0.0.1,::1,10.200.0.1}"
echo "    proxy=$PROXY_URL  ca=$CA_PATH"

# --- 4. Register the MCP server via the official CLI (idempotent) -----------
# `openclaw mcp set` writes the openclaw-managed mcp.servers config from a JSON
# object (transport inferred as stdio from `command`), INCLUDING the egress env
# above. Preferred over a raw JSON patch: it targets the right config key.
echo "==> Registering MCP server '$PRESET' (openclaw mcp set, with proxy/CA env) ..."
MCP_JSON="$(MCP_DST="$SERVER_DST" PROXY_URL="$PROXY_URL" CA_PATH="$CA_PATH" NOPROXY="$NOPROXY" python3 - <<'PY'
import json, os
print(json.dumps({
  "command": "node",
  "args": [os.environ["MCP_DST"]],
  "env": {
    "HTTPS_PROXY": os.environ["PROXY_URL"], "HTTP_PROXY": os.environ["PROXY_URL"],
    "NO_PROXY": os.environ["NOPROXY"], "NODE_USE_ENV_PROXY": "1",
    "NODE_EXTRA_CA_CERTS": os.environ["CA_PATH"],
  },
}))
PY
)"
dx998 openclaw mcp set "$PRESET" "$MCP_JSON" \
  && echo "    Registered (with proxy/CA egress env)." \
  || echo "    WARNING: 'openclaw mcp set' failed — check: nemoclaw $SANDBOX exec -- openclaw mcp list"

# --- 5. Rebuild the MCP runtime via a FULL gateway restart ------------------
# CRITICAL (v0.0.67 / OpenClaw 2026.5.27): registering an MCP server only triggers
# a config HOT-RELOAD, which does NOT rebuild the cached per-workspace MCP runtime —
# so the embedded agent keeps its OLD tool catalog (no calendar tools) and reports
# "no access to your calendar" over Telegram.
#   ⚠ This OpenClaw build has NO `openclaw mcp reload` (or `mcp probe`) subcommand —
#     only list/serve/set/show/unset. The old `openclaw mcp reload` call here was a
#     silent no-op (it errored "Too many arguments", swallowed by `|| true`), which
#     is exactly why the calendar stayed invisible. And `nemoclaw recover` only
#     hot-reloads on this macOS host-process topology. So the ONLY reliable way to
#     rebuild the runtime is a full gateway restart: kill -TERM the gateway worker
#     and let the nemoclaw-start supervisor relaunch a fresh gateway (which rebuilds
#     the MCP runtime from scratch, now including ms-calendar). Verified 2026-06-24.
echo "==> Restarting the gateway to rebuild the MCP runtime (no 'mcp reload' in this OpenClaw) ..."
GLOG="/tmp/gateway.log"
before="$(docker exec -u 0 "$CONTAINER" sh -c "wc -l < $GLOG 2>/dev/null" | tr -d '[:space:]')"
# Kill the supervised gateway worker by cmdline; the supervisor (nemoclaw-start)
# relaunches it. pkill -f excludes itself, and only the gateway worker carries
# "gateway run" in its cmdline.
# Find the gateway worker = the `openclaw` process supervised by nemoclaw-start.
# NOTE: its cmdline may be just "openclaw" (argv rewritten, no "gateway run" string)
# on some onboards, so match by process NAME + PARENT, not by "gateway run".
GWPID="$(docker exec -u 0 "$CONTAINER" sh -c '
  for p in $(pgrep -x openclaw 2>/dev/null); do
    pp=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
    tr "\0" " " < /proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }
  done' 2>/dev/null | head -1)"
if [ -n "$GWPID" ]; then
  docker exec -u 0 "$CONTAINER" sh -c "kill -TERM $GWPID" \
    && echo "    Sent TERM to the gateway worker (pid $GWPID); supervisor relaunching a fresh gateway ..."
else
  echo "    NOTE: gateway worker not found by name+parent; falling back to nemoclaw recover."
  nemoclaw "$SANDBOX" recover >/dev/null 2>&1 || true
fi

# Health check from the gateway LOG (authoritative) — NOT ss/netstat/proc, which
# all false-negative here: the gateway runs in its own network namespace, so a
# `docker exec` can't see its listener even when it's healthy. We instead confirm
# the supervisor wrote a fresh "ready"/"listening" line after our restart.
echo "==> Verifying the gateway came back up (log: 'http server listening' / 'ready') ..."
ok=""
for _ in 1 2 3 4 5 6 7 8; do
  if docker exec -u 0 "$CONTAINER" sh -c "tail -n +$(( ${before:-0} + 1 )) $GLOG 2>/dev/null" \
       | grep -qiE "http server listening|\[gateway\] ready"; then ok=1; break; fi
  sleep 5
done
if [ -n "$ok" ]; then
  echo "    Gateway restarted cleanly (fresh 'listening'/'ready' in $GLOG) — MCP runtime rebuilt."
else
  echo "    NOTE: no fresh restart line yet. Re-check the log, or restart by hand:"
  echo "      docker exec -u 0 $CONTAINER sh -c 'pkill -TERM -f \"gateway run\"'   # supervisor relaunches it"
fi

# --- 6. Verify --------------------------------------------------------------
echo "==> Verifying ..."
# NOTE: this OpenClaw (2026.5.27) has no `openclaw mcp probe` — use `mcp list`/`show`
# to confirm registration, and the direct stdio `diagnostics` call below for the
# functional check (egress + auth). The diagnostics run in the open MAIN netns, so a
# PASS proves creds/auth/egress-reachability but NOT the gateway-netns path — the
# real Telegram test is the final word.
echo "    --- registered MCP servers (openclaw mcp list): ---"
dx998 openclaw mcp list 2>&1 | grep -v -E 'qqbot|Config warnings|│|◇|├|╮|╯' | head -10 || true

echo "    --- diagnostics (egress + $([ "$CREDS" = 1 ] && echo auth || echo 'egress only')): ---"
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}' \
  | dx998i node "$SERVER_DST" 2>/dev/null \
  | python3 -c "import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        m=json.loads(line)
        if m.get('id')==2: print(m['result']['content'][0]['text'])
    except Exception: pass" | sed 's/^/      /'

echo
echo "==> Done."
echo "   Read tools: list_events, get_event, list_calendars, whoami, diagnostics"
if [ "$WRITE_ON" = 1 ]; then
  echo "   Write tools (ENABLED): create_event, update_event, delete_event"
  echo "   ⚠️  Write mode needs a Calendars.ReadWrite token — if writes 401, re-mint:"
  echo "       node tools/ms-graph-login.mjs <CLIENT_ID>   (defaults to the ReadWrite scope)"
else
  echo "   Write tools: disabled (read-only). Enable with: MS_CALENDAR_WRITE=1 ./runmod-finn-live.sh"
fi
if [ "$CREDS" = 1 ]; then
  echo "   Try over Telegram:  \"what's on my calendar this week\"$([ "$WRITE_ON" = 1 ] && echo '  /  \"add a 3pm meeting tomorrow called Sync\"')"
else
  echo "   Calendar tools are INACTIVE until you inject credentials:"
  echo "     node tools/ms-graph-login.mjs <CLIENT_ID>"
  echo "     export MS_CALENDAR_CLIENT_ID=... MS_CALENDAR_REFRESH_TOKEN=...; $([ "$WRITE_ON" = 1 ] && echo 'MS_CALENDAR_WRITE=1 ')./runmod-finn-live.sh"
fi
