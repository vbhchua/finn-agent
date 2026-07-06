#!/usr/bin/env bash
set -euo pipefail

# runmod-notion-live.sh
#
# "runmod" = a RUNTIME MODIFICATION of a LIVE, already-running finn sandbox
# (vs setup-finn.sh, which onboards the sandbox and wires search/fetch/Telegram).
# It mutates the running gateway's config + policy in place and does NOT rebuild
# the image — so it must be re-applied after a full rebuild/onboard.
# Standalone optional add-on: run it AFTER ./setup-finn.sh; not invoked by it.
#
# Adds NOTION access to a running finn via a zero-dependency Notion MCP server
# (mcp/notion-mcp.mjs) that talks to the Notion REST API (api.notion.com) using a
# Notion INTERNAL INTEGRATION TOKEN. Read-only by default; create/update/append
# tools are an explicit opt-in (NOTION_WRITE=1).
#
# We deliberately use Notion's LOCAL server + a static bearer token, NOT the hosted
# Notion MCP (mcp.notion.com) — the hosted one is OAuth-only with a human browser
# flow and can't drive a headless, Telegram-reached sandbox.
#
# PREREQUISITES (one-time, in your browser):
#   1. Create an internal integration at https://www.notion.so/profile/integrations
#      (Configuration tab → copy the "Internal Integration Secret", ntn_...).
#      For write mode, give it Insert/Update content capability; for read-only,
#      "Read content" only.
#   2. SHARE the pages/databases you want finn to access WITH that integration
#      (page ··· menu → Connections → add it). The integration sees only what's shared.
#   3. Export the token and run this script:
#        export NOTION_TOKEN='ntn_...'
#        ./runmod-notion-live.sh                 # read-only
#        NOTION_WRITE=1 ./runmod-notion-live.sh  # read/write (create/update/append)
#
# Running WITHOUT NOTION_TOKEN still wires everything up and validates network
# egress (the `diagnostics` tool) — the Notion tools just stay unauthenticated
# until you re-run with the token set.

SANDBOX="${SANDBOX:-finn}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESET="notion"
SERVER_SRC="$HERE/mcp/notion-mcp.mjs"
SERVER_DST="/sandbox/mcp/notion-mcp.mjs"
ENV_FILE="/sandbox/.config/notion.env"
PRESETS_DIR="${PRESETS_DIR:-$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets}"

# Write tools (create/update/append) are an explicit opt-in — default read-only.
case "${NOTION_WRITE:-0}" in 1|true|yes|on|TRUE|YES|ON) WRITE_ON=1 ;; *) WRITE_ON=0 ;; esac
NOTION_VERSION="${NOTION_VERSION:-2022-06-28}"

echo "==> Sandbox:     $SANDBOX"
echo "==> MCP server:  $SERVER_SRC -> $SERVER_DST"
echo "==> Mode:        $([ "$WRITE_ON" = 1 ] && echo 'READ-WRITE (create/update/append enabled)' || echo 'read-only (set NOTION_WRITE=1 to enable writes)')"
echo "==> Presets dir: $PRESETS_DIR"

[ -f "$SERVER_SRC" ] || { echo "ERROR: $SERVER_SRC not found." >&2; exit 1; }

CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
[ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (is $SANDBOX up? run ./setup-finn.sh first)." >&2; exit 1; }
echo "==> Container:   $CONTAINER"

dx998()  { docker exec -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }       # act as the sandbox user
dx998i() { docker exec -i -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }    # ...with stdin attached (piped JSON-RPC)

# --- 1. Register + activate the least-privilege network policy --------------
# api.notion.com only. Copy into the blueprint, then activate BY NAME (--from-file
# would collide once registered — see docs/LEARNINGS.md §6).
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
if [ -n "${NOTION_TOKEN:-}" ]; then
  echo "==> Writing credentials to $ENV_FILE (mode 0600) ..."
  docker exec -u 998 -e HOME=/sandbox \
    -e TOK="$NOTION_TOKEN" -e VER="$NOTION_VERSION" -e WR="$WRITE_ON" \
    "$CONTAINER" sh -c '
      umask 077; mkdir -p /sandbox/.config;
      {
        echo "NOTION_TOKEN=$TOK";
        echo "NOTION_VERSION=$VER";
        echo "NOTION_WRITE=$WR";
      } > /sandbox/.config/notion.env'
  echo "    Credentials written (token + write=$WRITE_ON)."
  CREDS=1
else
  echo "==> NOTE: NOTION_TOKEN not set."
  echo "    Wiring everything up anyway; Notion tools stay unauthenticated until you create an"
  echo "    integration (notion.so/profile/integrations), share pages with it, and re-run with"
  echo "    NOTION_TOKEN set."
  # Still write the non-secret settings so write-mode/version are correct once a token is added.
  docker exec -u 998 -e HOME=/sandbox -e VER="$NOTION_VERSION" -e WR="$WRITE_ON" "$CONTAINER" sh -c '
    umask 077; mkdir -p /sandbox/.config;
    if [ ! -f /sandbox/.config/notion.env ]; then printf "NOTION_VERSION=%s\nNOTION_WRITE=%s\n" "$VER" "$WR" > /sandbox/.config/notion.env; fi'
  CREDS=0
fi

# --- 3.5 Derive the egress env the MCP child needs --------------------------
# The MCP server self-bootstraps its proxy+CA by re-execing (see mcp/notion-mcp.mjs
# "THE EGRESS TRAP"), so this env block is belt-and-suspenders / forward-compat:
# OpenClaw scrubs it today, but we set it anyway in case a future build honors it.
echo "==> Deriving the proxy + CA env (the server also self-bootstraps it) ..."
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
# CRITICAL (OpenClaw 2026.5.27): registering an MCP server only triggers a config
# HOT-RELOAD, which does NOT rebuild the cached per-workspace MCP runtime — so the
# embedded agent keeps its OLD tool catalog (no Notion tools) and reports "no
# access." This OpenClaw build has NO `openclaw mcp reload` subcommand, and
# `nemoclaw recover` only hot-reloads here. So the ONLY reliable way to rebuild the
# runtime is a full gateway restart: kill -TERM the gateway worker and let the
# nemoclaw-start supervisor relaunch a fresh gateway. (See docs/LEARNINGS.md §2, the cached MCP runtime.)
echo "==> Restarting the gateway to rebuild the MCP runtime (no 'mcp reload' in this OpenClaw) ..."
GLOG="/tmp/gateway.log"
before="$(docker exec -u 0 "$CONTAINER" sh -c "wc -l < $GLOG 2>/dev/null" | tr -d '[:space:]')"
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
  echo "      docker exec -u 0 $CONTAINER sh -c 'pkill -TERM -f \"gateway run\"'"
fi

# --- 6. Verify --------------------------------------------------------------
echo "==> Verifying ..."
echo "    --- registered MCP servers (openclaw mcp list): ---"
dx998 openclaw mcp list 2>&1 | grep -v -E 'UNDICI|trace-warn|qqbot|Config warnings|│ +-|◇|├|╮|╯' | head -10 || true

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
echo "   Read tools: search, get_page, get_page_content, get_database, query_database, whoami, diagnostics"
if [ "$WRITE_ON" = 1 ]; then
  echo "   Write tools (ENABLED): create_page, update_page, append_blocks"
  echo "   ⚠️  Write mode also needs the integration to have Insert/Update content capability in Notion."
else
  echo "   Write tools: disabled (read-only). Enable with: NOTION_WRITE=1 ./runmod-notion-live.sh"
fi
if [ "$CREDS" = 1 ]; then
  echo "   Try over Telegram:  \"search my Notion for <topic>\"  /  \"what's in my <database> database\""
else
  echo "   Notion tools are UNAUTHENTICATED until you add a token:"
  echo "     create an integration at notion.so/profile/integrations, share pages with it, then:"
  echo "     export NOTION_TOKEN=ntn_...; $([ "$WRITE_ON" = 1 ] && echo 'NOTION_WRITE=1 ')./runmod-notion-live.sh"
fi
