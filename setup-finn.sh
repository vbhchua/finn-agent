#!/usr/bin/env bash
set -euo pipefail

# setup-finn.sh — ONE idempotent, .env-driven configurator for the finn sandbox.
#
# Folds the former runmod-*.sh add-ons (models · calendar · notion · radar) into a
# single pass. Everything is driven by .env (template: .env.sample); each layer is
# applied only if its env is present, and every layer is safe to re-run after a
# rebuild/onboard. Run it after the sandbox is onboarded:
#
#     nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn   # (see SETUP.md; base build first)
#     ./setup-finn.sh                                                   # configures everything from .env
#
# The script auto-sources ./.env if present, so a bare `./setup-finn.sh` works.
#
# Layers (order matters — Telegram REBUILDS the image, which wipes runtime config,
# so it runs before every runtime layer; the single gateway restart at the end loads
# the model + MCP runtime + fetch provider; radar registers crons against the live gateway):
#   1. onboard (stock) if the sandbox is missing        (SKIP_ONBOARD=1 to require it exists)
#   2. Telegram channel                                  TELEGRAM_BOT_TOKEN
#   3. Brave web SEARCH (key + egress)                   BRAVE_API_KEY
#   4. Firecrawl full-page FETCH                          FIRECRAWL_API_KEY
#   5. Inference model (compatible-endpoint primary + optional OpenRouter fallback)
#                                                         INFERENCE_MODEL_ID / OPENROUTER_API_KEY
#   6. Outlook CALENDAR MCP                               MS_CALENDAR_CLIENT_ID + MS_CALENDAR_REFRESH_TOKEN
#   7. Notion MCP                                         NOTION_TOKEN
#   8. Proactive radar crons (conf-radar/topic-trends/weekly-digest)   NOTION_TOKEN
#
# Env knobs: SANDBOX (default finn), SEARCH_PROVIDER (brave), SKIP_ONBOARD=1,
#   NOTION_WRITE=1, MS_CALENDAR_WRITE=1, DRYRUN=1 (run conf-radar once), TELEGRAM_CHAT_ID,
#   ONLY="models notion" (run just these layers), SKIP="radar" (skip these layers).

HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- All config lives in .env (auto-source if present; already-exported vars win via set -a order) ----
if [ -f "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

SANDBOX="${SANDBOX:-finn}"
SEARCH_PROVIDER="${SEARCH_PROVIDER:-brave}"

# Inference (generalized from the old KIMI_* knobs so ANY OpenAI-compatible endpoint works):
INFERENCE_MODEL_ID="${INFERENCE_MODEL_ID:-kimi-k2.6}"           # sandbox primary = inference/$INFERENCE_MODEL_ID
INFERENCE_ENDPOINT_URL="${INFERENCE_ENDPOINT_URL:-https://api.moonshot.ai/v1}"  # host-side, registered at onboard (informational here)
INFERENCE_CONTEXT_WINDOW="${INFERENCE_CONTEXT_WINDOW:-262144}"
INFERENCE_MAX_TOKENS="${INFERENCE_MAX_TOKENS:-32768}"  # k2.6 reasons in-band: 8192 starves visible output (LEARNINGS §13)
OPENROUTER_MODEL="${OPENROUTER_MODEL:-openrouter/moonshotai/kimi-k2.6}"
DOCKERFILE="${DOCKERFILE:-$HERE/Dockerfile.finn-2026.6.10}"

# Keep the BAKED model pin in sync with .env — .env is the single source of truth.
# nemoclaw builds the Dockerfile itself with no --build-arg (LEARNINGS §6), so the ARG
# *defaults* are what get baked into the image; if they drift from the endpoint/model
# registered at onboard, every recreate (e.g. `channels add telegram`) resets the
# sandbox to a stale pin and loops on the compatible-endpoint smoke check (§12).
sync_dockerfile_pin() {
  [ -f "$DOCKERFILE" ] || { echo "==> Pin sync: $DOCKERFILE not found — skipping."; return 0; }
  local changed=0 key val
  for key in INFERENCE_MODEL_ID INFERENCE_CONTEXT_WINDOW INFERENCE_MAX_TOKENS; do
    eval "val=\$$key"
    grep -q "^ARG $key=" "$DOCKERFILE" || { echo "    WARNING: ARG $key not found in $DOCKERFILE — is step 2c missing?"; continue; }
    grep -q "^ARG $key=$val\$" "$DOCKERFILE" && continue
    sed -i "s|^ARG $key=.*|ARG $key=$val|" "$DOCKERFILE"; changed=1
  done
  if [ "$changed" = 1 ]; then echo "==> Synced baked model-pin ARGs in ${DOCKERFILE##*/} from .env (model=$INFERENCE_MODEL_ID)."
  else echo "==> Baked model-pin ARGs already match .env (model=$INFERENCE_MODEL_ID)."; fi
}

NOTION_VERSION="${NOTION_VERSION:-2022-06-28}"
MS_CALENDAR_TENANT="${MS_CALENDAR_TENANT:-consumers}"
MS_CALENDAR_TZ="${MS_CALENDAR_TZ:-UTC}"
TZ_CRON="${TZ_CRON:-Asia/Singapore}"
JOB_TIMEOUT="${JOB_TIMEOUT:-900}"
SBX_RADAR="/sandbox/.cache/radar"
case "${NOTION_WRITE:-0}"      in 1|true|yes|on|TRUE|YES|ON) NOTION_WRITE_ON=1 ;; *) NOTION_WRITE_ON=0 ;; esac
case "${MS_CALENDAR_WRITE:-0}" in 1|true|yes|on|TRUE|YES|ON) MSCAL_WRITE_ON=1 ;; *) MSCAL_WRITE_ON=0 ;; esac

# ONLY / SKIP layer selection (space-separated layer names).
want() {  # $1 = layer name -> true if it should run
  local l="$1"
  if [ -n "${ONLY:-}" ]; then case " $ONLY " in *" $l "*) : ;; *) return 1 ;; esac; fi
  if [ -n "${SKIP:-}" ]; then case " $SKIP " in *" $l "*) return 1 ;; esac; fi
  return 0
}

# ---- 0. NemoClaw version preflight (built + verified against v0.0.68 exactly) ----
NEMOCLAW_VERSION_EXPECTED="v0.0.68"
verlt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]; }
if [ -z "${NEMOCLAW_VERSION_SKIP_CHECK:-}" ]; then
  nv="$(nemoclaw --version 2>/dev/null | head -1 | grep -o 'v[0-9][0-9.]*' || true)"
  if [ -z "$nv" ]; then
    echo "ERROR: cannot determine the nemoclaw version; expected $NEMOCLAW_VERSION_EXPECTED (or NEMOCLAW_VERSION_SKIP_CHECK=1)." >&2; exit 1
  elif [ "$nv" = "$NEMOCLAW_VERSION_EXPECTED" ]; then echo "==> NemoClaw:  $nv (verified)"
  elif verlt "${nv#v}" "${NEMOCLAW_VERSION_EXPECTED#v}"; then
    echo "ERROR: nemoclaw $nv is OLDER than $NEMOCLAW_VERSION_EXPECTED — no OpenClaw 2026.6.x patch support; aborting." >&2; exit 1
  else echo "==> NemoClaw:  $nv — newer than the verified $NEMOCLAW_VERSION_EXPECTED; untested, continuing." >&2; fi
fi

echo "==> Sandbox:   $SANDBOX"
echo "==> Layers:    ${ONLY:+ONLY='$ONLY' }${SKIP:+SKIP='$SKIP' }(each also skipped if its env is unset)"

# ============================ shared helpers ============================
# nemoclaw exec as the sandbox user (config gets/sets go through this).
# NemoClaw >= v0.0.73 intercepts `openclaw config set` under `nemoclaw exec`
# ("cannot modify config inside the sandbox" + a rebuild nudge), which broke the
# search/fetch/mcp layers. Go straight to the container instead — same uid/HOME,
# re-resolving the container name per call since it changes on every rebuild.
oc() { find_container || return 1; docker exec -i -u 998 -e HOME=/sandbox "$CONTAINER" bash -c "$*" 2>/dev/null; }

CONTAINER=""
find_container() {  # re-resolve — the name/UUID changes on every rebuild
  CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
  [ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (is $SANDBOX onboarded/up?)." >&2; return 1; }
}
dx0()    { docker exec -u 0 "$CONTAINER" "$@"; }
dx998()  { docker exec -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }
dx998i() { docker exec -i -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }
gw()     { dx0 "$SBX_RADAR/gw-cron.sh" "$@"; }

# npm root -g is brittle under nvm; follow the nemoclaw launcher to the blueprint as a fallback.
resolve_presets_dir() {
  local d launcher real execpath
  d="$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets"
  [ -d "$d" ] && { echo "$d"; return; }
  launcher="$(command -v nemoclaw 2>/dev/null || true)"; [ -n "$launcher" ] || { echo ""; return; }
  real="$(readlink -f "$launcher" 2>/dev/null || true)"
  case "$real" in *nemoclaw.js) : ;; *)
    execpath="$(grep -oE '"[^"]*/bin/nemoclaw"' "$real" 2>/dev/null | tr -d '"' | head -1)"
    [ -n "$execpath" ] && real="$(readlink -f "$execpath" 2>/dev/null || true)" ;;
  esac
  d="$(dirname "$real")/../nemoclaw-blueprint/policies/presets"
  [ -d "$d" ] && (cd "$d" && pwd) || echo ""
}
PRESETS_DIR="${PRESETS_DIR:-$(resolve_presets_dir)}"

# Register a bundled/vendored egress preset by NAME (copy the yaml into the blueprint if we ship one;
# activate by name — --from-file collides once registered, LEARNINGS §6).
apply_policy() {  # $1 = preset name
  local p="$1"
  if [ -f "$HERE/fixes/$p.yaml" ] && [ -d "$PRESETS_DIR" ]; then cp "$HERE/fixes/$p.yaml" "$PRESETS_DIR/"; fi
  echo "==> policy-add $p ..."
  nemoclaw "$SANDBOX" policy-add "$p" --yes \
    || echo "    (policy-add $p non-zero — may already be applied; nemoclaw $SANDBOX policy-list)"
}

# The gateway spawns MCP children with a SCRUBBED env in a proxy-only netns (LEARNINGS §1).
# Recover the gateway's own proxy + CA so `openclaw mcp set` can bake them into the child env.
PROXY_URL="" CA_PATH="" NOPROXY=""
derive_proxy_ca() {
  local gwenv
  gwenv="$(dx0 sh -c '
    for p in $(pgrep -x openclaw 2>/dev/null); do
      if tr "\0" "\n" < /proc/$p/environ 2>/dev/null | grep -q "^NODE_EXTRA_CA_CERTS="; then
        tr "\0" "\n" < /proc/$p/environ 2>/dev/null; break; fi
    done' 2>/dev/null)"
  PROXY_URL="$(printf '%s\n' "$gwenv" | sed -n 's/^HTTPS_PROXY=//p' | head -1)";       PROXY_URL="${PROXY_URL:-http://10.200.0.1:3128}"
  CA_PATH="$(printf '%s\n' "$gwenv"  | sed -n 's/^NODE_EXTRA_CA_CERTS=//p' | head -1)"; CA_PATH="${CA_PATH:-/etc/openshell-tls/openshell-ca.pem}"
  NOPROXY="$(printf '%s\n' "$gwenv"  | sed -n 's/^NO_PROXY=//p' | head -1)";            NOPROXY="${NOPROXY:-localhost,127.0.0.1,::1,10.200.0.1}"
}

# Install a zero-dep MCP server into the sandbox + register it (with proxy/CA egress env).
install_mcp() {  # $1=name  $2=src(.mjs)  $3=dst
  local name="$1" src="$2" dst="$3" mcp_json
  [ -f "$src" ] || { echo "ERROR: MCP server $src not found." >&2; return 1; }
  dx998 mkdir -p "$(dirname "$dst")"
  docker cp "$src" "$CONTAINER:$dst"
  dx0 sh -c "chown 998:998 '$dst' && chmod 644 '$dst'"
  mcp_json="$(MCP_DST="$dst" PROXY_URL="$PROXY_URL" CA_PATH="$CA_PATH" NOPROXY="$NOPROXY" python3 - <<'PY'
import json, os
print(json.dumps({"command":"node","args":[os.environ["MCP_DST"]],"env":{
  "HTTPS_PROXY":os.environ["PROXY_URL"],"HTTP_PROXY":os.environ["PROXY_URL"],
  "NO_PROXY":os.environ["NOPROXY"],"NODE_USE_ENV_PROXY":"1","NODE_EXTRA_CA_CERTS":os.environ["CA_PATH"]}}))
PY
)"
  dx998 openclaw mcp set "$name" "$mcp_json" \
    && echo "    Registered MCP '$name'." \
    || echo "    WARNING: 'openclaw mcp set $name' failed — nemoclaw $SANDBOX exec -- openclaw mcp list"
}

# Full gateway restart = the ONLY reliable way to load model config + rebuild the MCP runtime on this
# OpenClaw (no `mcp reload`; `recover` only hot-reloads). TERM the gateway worker; the nemoclaw-start
# supervisor relaunches a fresh gateway. Health is LOG-authoritative (LEARNINGS §2/§3). NEVER docker restart (§5).
restart_gateway() {
  echo "==> Restarting the gateway (load model + rebuild MCP runtime) ..."
  local before ok=""
  before="$(dx0 sh -c 'wc -l < /tmp/gateway.log 2>/dev/null' | tr -d '[:space:]')"
  local gwpid
  gwpid="$(dx0 sh -c '
    for p in $(pgrep -x openclaw 2>/dev/null); do
      pp=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
      tr "\0" " " < /proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }
    done' 2>/dev/null | head -1)"
  if [ -n "$gwpid" ]; then
    dx0 sh -c "kill -TERM $gwpid" && echo "    TERM -> gateway worker (pid $gwpid); supervisor relaunching ..."
  else
    echo "    gateway worker not found by name+parent; falling back to nemoclaw recover."
    nemoclaw "$SANDBOX" recover >/dev/null 2>&1 || true
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    if dx0 sh -c "tail -n +$(( ${before:-0} + 1 )) /tmp/gateway.log 2>/dev/null" | grep -qiE "http server listening|\[gateway\] ready"; then ok=1; break; fi
    sleep 5
  done
  [ -n "$ok" ] && echo "    Gateway back up (fresh 'listening'/'ready')." \
              || echo "    NOTE: no fresh ready line yet; re-check /tmp/gateway.log."
}

# Functional check for an MCP server via a direct stdio diagnostics call (main netns — proves
# egress/auth reachability, NOT the gateway-netns path; the Telegram test is the final word).
mcp_diagnostics() {  # $1 = server dst
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"setup","version":"0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}' \
    | dx998i node "$1" 2>/dev/null \
    | python3 -c "import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try:
        m=json.loads(line)
        if m.get('id')==2: print(m['result']['content'][0]['text'])
    except Exception: pass" | sed 's/^/      /'
}

# ============================ layers ============================

layer_onboard() {
  if nemoclaw "$SANDBOX" status >/dev/null 2>&1; then
    echo "==> $SANDBOX exists — skipping onboard."
  elif [ "${SKIP_ONBOARD:-0}" = 1 ]; then
    echo "ERROR: $SANDBOX missing and SKIP_ONBOARD=1. Run 'nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name $SANDBOX' (base build first — SETUP.md)." >&2; exit 1
  else
    # Clear a lingering custom brave provider PROFILE so onboard's import doesn't collide (no --force).
    openshell provider profile delete brave >/dev/null 2>&1 || true
    echo "==> Onboarding $SANDBOX (stock image — gateway + brave search) ..."
    nemoclaw onboard --name "$SANDBOX"
  fi
}

layer_telegram() {  # rebuilds the image (bakes the token) — MUST precede runtime layers
  if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then echo "==> Telegram: TELEGRAM_BOT_TOKEN unset — skipping."; return; fi
  if [ "$(oc 'openclaw config get channels.telegram.enabled' | tail -1)" = "true" ]; then
    echo "==> Telegram already enabled — leaving as-is."; return
  fi
  echo "==> Adding Telegram channel (REBUILDS the image to bake the token) ..."
  # Non-interactive: feed the token + confirm the rebuild. (Interactive fallback if no token piped.)
  printf '%s\ny\n' "$TELEGRAM_BOT_TOKEN" | nemoclaw "$SANDBOX" channels add telegram \
    || echo "    NOTE: 'channels add telegram' did not complete — re-run by hand."
  echo "    After it rebuilds: DM the bot, then  nemoclaw $SANDBOX exec -- openclaw pairing list telegram  /  approve telegram <CODE>"
}

layer_search() {  # Brave key + egress (onboard only injects on a FRESH onboard with the key present)
  if [ -z "${BRAVE_API_KEY:-}" ]; then echo "==> Search: BRAVE_API_KEY unset — relying on onboard injection (may be unkeyed after a re-onboard)."; return; fi
  apply_policy brave
  echo "==> Injecting Brave key + pinning search=$SEARCH_PROVIDER ..."
  oc "openclaw config set tools.web.search.provider $SEARCH_PROVIDER" >/dev/null || true
  oc "openclaw config set plugins.entries.brave.config.webSearch.apiKey '$BRAVE_API_KEY'" >/dev/null \
    && echo "    Set webSearch.apiKey (brave)." || echo "    WARNING: failed to set brave apiKey."
}

layer_fetch() {  # Firecrawl full-page fetch (search stays on brave)
  if [ -z "${FIRECRAWL_API_KEY:-}" ]; then echo "==> Fetch: FIRECRAWL_API_KEY unset — search-only."; return; fi
  apply_policy firecrawl
  # 2026.6.x un-bundled firecrawl → install the version-matched plugin (or it's baked at build).
  local ocv
  ocv="$(oc 'openclaw --version' | awk '{print $2}' | tr -d '\r')"
  if [ -n "$ocv" ] && [ "$(printf '%s\n%s\n' "2026.6.0" "$ocv" | sort -V | head -n1)" = "2026.6.0" ]; then
    if oc 'openclaw plugins list' | grep -qiE 'firecrawl'; then
      echo "==> firecrawl plugin already installed/baked (OpenClaw $ocv)."
    else
      echo "==> Installing @openclaw/firecrawl-plugin@$ocv ..."
      oc "openclaw plugins install 'npm:@openclaw/firecrawl-plugin@$ocv' --pin" >/dev/null 2>&1 \
        && echo "    Installed (needs the gateway restart to load)." \
        || echo "    WARNING: runtime install failed (sandbox blocks npm egress) — BAKE it in Dockerfile.finn-2026.6.10 (RUN openclaw plugins install ... --pin)."
    fi
  fi
  echo "==> Pointing web_fetch at firecrawl + injecting key ..."
  oc "openclaw config set plugins.entries.firecrawl.enabled true" >/dev/null || true
  oc "openclaw config set tools.web.fetch.provider firecrawl" >/dev/null || true
  oc "openclaw config set plugins.entries.firecrawl.config.webFetch.baseUrl https://api.firecrawl.dev" >/dev/null || true
  oc "openclaw config set tools.web.search.provider $SEARCH_PROVIDER" >/dev/null || true
  oc "openclaw config set plugins.entries.firecrawl.config.webFetch.apiKey '$FIRECRAWL_API_KEY'" >/dev/null \
    && echo "    Set web_fetch=firecrawl + key." || echo "    WARNING: failed to set firecrawl apiKey."
  # /etc/hosts: the firecrawl SSRF precheck resolves via the LOCAL resolver — point it at any public IP.
  local fc_ip
  fc_ip="$( { dig +short api.firecrawl.dev A 2>/dev/null; } | grep -E '^[0-9]+\.' | head -1 )"; fc_ip="${fc_ip:-35.245.250.27}"
  dx0 sh -c "grep -q 'api.firecrawl.dev' /etc/hosts || echo '$fc_ip api.firecrawl.dev' >> /etc/hosts" \
    && echo "    /etc/hosts: $fc_ip api.firecrawl.dev" || echo "    WARNING: failed to add /etc/hosts alias."
}

layer_models() {  # inference primary = compatible-endpoint model; optional OpenRouter fallback
  echo "==> Model: primary=inference/$INFERENCE_MODEL_ID (endpoint $INFERENCE_ENDPOINT_URL, key gateway-side)"
  [ -n "${OPENROUTER_API_KEY:-}" ] && apply_policy openrouter
  docker exec -i -u 998 -e HOME=/sandbox \
    -e MID="$INFERENCE_MODEL_ID" -e CTX="$INFERENCE_CONTEXT_WINDOW" -e MAX="$INFERENCE_MAX_TOKENS" \
    -e OR_MODEL="$OPENROUTER_MODEL" -e OR_KEY="${OPENROUTER_API_KEY:-}" \
    "$CONTAINER" python3 - <<'PY'
import json, os, shutil
p="/sandbox/.openclaw/openclaw.json"; mid=os.environ["MID"]; or_model=os.environ["OR_MODEL"]; or_key=os.environ.get("OR_KEY","")
shutil.copy(p, p+".pre-models"); cfg=json.load(open(p))
d=cfg["agents"]["defaults"]; d.setdefault("model",{})["primary"]=f"inference/{mid}"
models=cfg["models"]["providers"]["inference"].setdefault("models",[])
# Replace-or-append so .env stays the single source of truth: an append-only guard
# silently ignores contextWindow/maxTokens changes on an already-registered model.
models[:]=[m for m in models if m.get("id")!=mid]
models.append({"id":mid,"name":f"inference/{mid}","reasoning":False,"input":["text"],
    "cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},
    "contextWindow":int(os.environ["CTX"]),"maxTokens":int(os.environ["MAX"])})
if or_key:
    cfg.setdefault("env",{})["OPENROUTER_API_KEY"]=or_key
    fb=d["model"].setdefault("fallbacks",[]); (or_model in fb) or fb.append(or_model)
    am=d.setdefault("models",{}); am.setdefault(f"inference/{mid}",{}); am.setdefault(or_model,{})
    print(f"    primary=inference/{mid}  fallbacks={fb}")
else:
    print(f"    primary=inference/{mid}  (no OpenRouter fallback)")
json.dump(cfg, open(p,"w"), indent=2)
PY
}

layer_calendar() {  # Outlook/Graph MCP (personal MSA via a delegated refresh token)
  local write="$MSCAL_WRITE_ON" scope
  if [ "$write" = 1 ]; then scope="https://graph.microsoft.com/Calendars.ReadWrite offline_access User.Read"
  else scope="https://graph.microsoft.com/Calendars.Read offline_access User.Read"; fi
  scope="${MS_CALENDAR_SCOPE:-$scope}"
  apply_policy ms-calendar
  install_mcp ms-calendar "$HERE/mcp/ms-calendar-mcp.mjs" /sandbox/mcp/ms-calendar-mcp.mjs || return
  if [ -n "${MS_CALENDAR_CLIENT_ID:-}" ] && [ -n "${MS_CALENDAR_REFRESH_TOKEN:-}" ]; then
    docker exec -u 998 -e HOME=/sandbox -e CID="$MS_CALENDAR_CLIENT_ID" -e RT="$MS_CALENDAR_REFRESH_TOKEN" \
      -e TEN="$MS_CALENDAR_TENANT" -e SC="$scope" -e TZ="$MS_CALENDAR_TZ" -e WR="$write" "$CONTAINER" sh -c '
        umask 077; mkdir -p /sandbox/.config
        { echo "MS_CALENDAR_CLIENT_ID=$CID"; echo "MS_CALENDAR_REFRESH_TOKEN=$RT"; echo "MS_CALENDAR_TENANT=$TEN";
          echo "MS_CALENDAR_SCOPE=$SC"; echo "MS_CALENDAR_TZ=$TZ"; echo "MS_CALENDAR_WRITE=$WR"; } > /sandbox/.config/ms-calendar.env'
    echo "    Calendar creds written (write=$write)."
  else
    echo "    NOTE: MS_CALENDAR_CLIENT_ID/REFRESH_TOKEN unset — calendar wired but inactive (mint: node tools/ms-graph-login.mjs <CLIENT_ID>)."
  fi
}

layer_notion() {  # Notion MCP (internal-integration token)
  if [ -z "${NOTION_TOKEN:-}" ]; then echo "==> Notion: NOTION_TOKEN unset — skipping."; return; fi
  apply_policy notion
  install_mcp notion "$HERE/mcp/notion-mcp.mjs" /sandbox/mcp/notion-mcp.mjs || return
  docker exec -u 998 -e HOME=/sandbox -e TOK="$NOTION_TOKEN" -e VER="$NOTION_VERSION" -e WR="$NOTION_WRITE_ON" "$CONTAINER" sh -c '
    umask 077; mkdir -p /sandbox/.config
    { echo "NOTION_TOKEN=$TOK"; echo "NOTION_VERSION=$VER"; echo "NOTION_WRITE=$WR"; } > /sandbox/.config/notion.env'
  echo "    Notion creds written (write=$NOTION_WRITE_ON)."
}

layer_radar() {  # proactive cron loops — needs NOTION_TOKEN + the Notion MCP + a live gateway
  if [ -z "${NOTION_TOKEN:-}" ]; then echo "==> Radar: NOTION_TOKEN unset — skipping."; return; fi
  local f; for f in notion-bootstrap.mjs gw-cron.sh grant-cron-admin.py prompts/conf-radar.md prompts/topic-trends.md prompts/weekly-digest.md; do
    [ -f "$HERE/radar/$f" ] || { echo "ERROR: radar/$f missing." >&2; return 1; }; done
  echo "==> Radar: bootstrapping Notion DBs (host-side) ..."
  local boot; boot="$(NOTION_TOKEN="$NOTION_TOKEN" node "$HERE/radar/notion-bootstrap.mjs")"; echo "    $boot"
  get() { printf '%s' "$boot" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
  local EVENTS_DB SPEAKERS_DB TOPICS_DB TRENDS_DB
  EVENTS_DB="$(get events_db)"; SPEAKERS_DB="$(get speakers_db)"; TOPICS_DB="$(get topics_db)"; TRENDS_DB="$(get trends_db)"
  [ -n "$EVENTS_DB" ] && [ -n "$TOPICS_DB" ] && [ -n "$TRENDS_DB" ] || { echo "ERROR: bootstrap returned no DB ids." >&2; return 1; }
  local CHAT_ID="${TELEGRAM_CHAT_ID:-}"
  [ -n "$CHAT_ID" ] || CHAT_ID="$(dx0 sh -c "grep -oiE 'chat[_ ]?id[\"= :]+-?[0-9]{6,}' /tmp/gateway.log 2>/dev/null | grep -oE '\-?[0-9]{6,}' | tail -1" || true)"
  [ -n "$CHAT_ID" ] && echo "==> Telegram chat id: $CHAT_ID" || echo "    WARNING: no chat id detected; DM finn once, re-run with TELEGRAM_CHAT_ID=<id>. Using last-channel fallback." >&2
  dx998 mkdir -p "$SBX_RADAR"
  docker cp "$HERE/radar/gw-cron.sh"          "$CONTAINER:$SBX_RADAR/gw-cron.sh"
  docker cp "$HERE/radar/grant-cron-admin.py" "$CONTAINER:$SBX_RADAR/grant-cron-admin.py"
  dx0 sh -c "chown 998:998 $SBX_RADAR/gw-cron.sh $SBX_RADAR/grant-cron-admin.py && chmod 755 $SBX_RADAR/gw-cron.sh"
  echo "==> Ensuring the CLI device has operator.admin (for cron add) ..."
  local grant; grant="$(dx998 python3 "$SBX_RADAR/grant-cron-admin.py" | tail -1)"; echo "    grant: $grant"
  [ "$grant" = "CHANGED" ] && restart_gateway
  fill_stage() {  local b="$1" tmp; tmp="$(mktemp)"
    sed -e "s|{{EVENTS_DB}}|$EVENTS_DB|g" -e "s|{{SPEAKERS_DB}}|$SPEAKERS_DB|g" -e "s|{{TOPICS_DB}}|$TOPICS_DB|g" \
        -e "s|{{TRENDS_DB}}|$TRENDS_DB|g" -e "s|{{CHAT_ID}}|$CHAT_ID|g" "$HERE/radar/prompts/$b.md" > "$tmp"
    docker cp "$tmp" "$CONTAINER:$SBX_RADAR/$b.msg"; dx0 sh -c "chown 998:998 $SBX_RADAR/$b.msg"; rm -f "$tmp"; }
  echo "==> Staging filled prompts ..."; fill_stage conf-radar; fill_stage topic-trends; fill_stage weekly-digest
  rm_by_name() { local ids; ids="$(gw cron list --json 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print('\n'.join(j.get('id','') for j in d.get('jobs',[]) if j.get('name')=='$1'))" 2>/dev/null || true)"
    local id; for id in $ids; do [ -n "$id" ] && gw cron rm "$id" >/dev/null 2>&1 || true; done; }
  add_job() { rm_by_name "$1"; echo "==> cron: $1 ($2 $TZ_CRON)"; local out
    out="$(dx0 sh -c "$SBX_RADAR/gw-cron.sh cron add --name '$1' --cron '$2' --tz '$TZ_CRON' --timeout-seconds '$JOB_TIMEOUT' $3 --message \"\$(cat '$SBX_RADAR/$4.msg')\"" 2>&1 | grep -viE 'qqbot|Config warn')"
    printf '%s' "$out" | grep -q '"id":' && echo "    ok" || { echo "    ERROR registering $1:" >&2; printf '%s\n' "$out" | tail -4 >&2; }; }
  local DELIVER="--announce --channel telegram"; [ -n "$CHAT_ID" ] && DELIVER="$DELIVER --to $CHAT_ID"
  add_job finn-conf-radar    "0 9 * * *"  "--session-key agent:main:conf-radar $DELIVER"        conf-radar
  add_job finn-topic-trends  "30 9 * * *" "--session-key agent:main:topic-trends $DELIVER"       topic-trends
  add_job finn-weekly-digest "0 10 * * 1" "--session-key agent:main:weekly-digest $DELIVER"     weekly-digest
  echo "==> Registered cron jobs:"; gw cron list 2>/dev/null | grep -iE 'finn-(conf-radar|topic-trends|weekly-digest)|^ID|Schedule' | head -10 || true
  if [ "${DRYRUN:-0}" = 1 ]; then
    echo "==> DRYRUN: running finn-conf-radar once (slow) ..."
    local rid; rid="$(gw cron list --json 2>/dev/null | python3 -c "import sys,json;print(next((j['id'] for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='finn-conf-radar'),''))" 2>/dev/null || true)"
    [ -n "$rid" ] && { gw cron run "$rid" --wait --wait-timeout 12m --poll-interval 5s || true; gw cron runs --id "$rid" --limit 1 || true; }
  fi
}

# ============================ driver ============================
# 1-2 first (onboard, then the Telegram REBUILD) — a rebuild wipes runtime config, so it must precede
# every runtime layer. 3-7 write config/policy/MCP; ONE restart loads them; 8 (radar) needs a live gateway.
sync_dockerfile_pin   # BEFORE anything that can (re)build the image
want onboard  && layer_onboard

find_container_or_die() { find_container || { echo "ERROR: no running $SANDBOX container — onboard first." >&2; exit 1; }; }

want telegram && layer_telegram
# (re-resolve the container: channels-add rebuilt it under a new UUID)
find_container_or_die
derive_proxy_ca

RUNTIME=0
want search   && { layer_search;   RUNTIME=1; }
want fetch    && { layer_fetch;    RUNTIME=1; }
want models   && { layer_models;   RUNTIME=1; }
want calendar && { layer_calendar; RUNTIME=1; }
want notion   && { layer_notion;   RUNTIME=1; }

# One restart loads model + MCP runtime + fetch provider (radar restarts again only if it grants admin).
[ "$RUNTIME" = 1 ] && restart_gateway

want radar    && layer_radar

# ---- verify snapshot ----
echo; echo "==> Config snapshot:"
printf "    inference primary : %s\n" "$(oc 'openclaw config get agents.defaults.model.primary' | tail -1)"
printf "    search provider   : %s\n" "$(oc 'openclaw config get tools.web.search.provider' | tail -1)"
printf "    fetch provider    : %s\n" "$(oc 'openclaw config get tools.web.fetch.provider' | tail -1)"
printf "    telegram          : %s\n" "$(oc 'openclaw config get channels.telegram.enabled' | tail -1)"
echo "==> MCP servers:"; dx998 openclaw mcp list 2>&1 | grep -viE 'UNDICI|trace-warn|Config warn|◇|├|╮|╯|│ +-' | head -8 || true
echo
echo "✅ Done. Final word is a live prompt over Telegram (search/fetch/calendar/notion), then approve the Telegram pairing if new."
echo "   Re-run any time (idempotent); ONLY='models' / SKIP='radar' scope it. All config comes from .env."
