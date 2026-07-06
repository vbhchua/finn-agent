#!/usr/bin/env bash
set -euo pipefail

# runmod-conference-radar-live.sh
#
# "runmod" = a RUNTIME MODIFICATION of a LIVE, already-running finn sandbox (vs setup-finn.sh
# which onboards it). Re-apply after a full rebuild/onboard. Standalone optional add-on: run it
# AFTER ./setup-finn.sh and ./runmod-notion-live.sh (it needs the Notion MCP wired).
#
# Adds finn's PROACTIVE layer (Features 4 & 5) on top of the existing event-intelligence Notion:
#   • Feature 4 — Conference Radar: a DAILY gateway cron job that re-checks UPCOMING events on an
#     adaptive cadence (tighter as an event nears), updates "📅 AI Events — Singapore", and
#     Telegram-pings on a material change.
#   • Feature 5 — Topic Trends: a WEEKLY cron job that snapshots which Themes are gaining/losing
#     traction (writes "finn · Trend snapshots"; silent — feeds the digest).
#   • Weekly digest: a MONDAY cron job that reports both to Telegram in one message.
#
# Strong-model-authors / weak-model-executes: a frontier model (Opus 4.8) did the one-time data
# bootstrap + authored radar/prompts/*.md; the in-sandbox Nemotron just executes them on the loop.
#
# THREE non-obvious mechanics this script encapsulates (full writeup in docs/LEARNINGS.md §7):
#   1. Notion DBs are created/patched HOST-side (the MCP has no create_database; keeps DB schema
#      changes off the agent surface).  → radar/notion-bootstrap.mjs (needs NOTION_TOKEN on host).
#   2. `openclaw cron` is a live WS client to the gateway, which runs in its OWN netns → it must
#      run via nsenter INSIDE that netns.  → radar/gw-cron.sh.
#   3. `cron add` needs operator.admin, but a headless onboard has no admin device to approve the
#      upgrade → we grant it in the on-disk device table + restart.  → radar/grant-cron-admin.py.
#
# PREREQUISITES:
#   1. ./setup-finn.sh  and  NOTION_WRITE=1 ./runmod-notion-live.sh  already applied.
#   2. NOTION_TOKEN exported on THIS host (same token as the Notion connector).
#   3. The "AI Events Singapore — BD Intelligence Hub" page + its two DBs already shared with the
#      "Openclaw Notion" integration (they are — that's the event-intelligence bootstrap).
#
# Usage:
#   export NOTION_TOKEN='ntn_...'
#   ./runmod-conference-radar-live.sh                 # bootstrap + register the 3 cron jobs
#   DRYRUN=1 ./runmod-conference-radar-live.sh        # ...and run conf-radar once now (~minutes)
#   TELEGRAM_CHAT_ID=123456789 ./runmod-...sh          # force the Telegram delivery chat id

SANDBOX="${SANDBOX:-finn}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RADAR="$HERE/radar"
TZ_CRON="${TZ_CRON:-Asia/Singapore}"
JOB_TIMEOUT="${JOB_TIMEOUT:-900}"        # Nemotron turns are slow; head-room (seconds)
SBX_RADAR="/sandbox/.cache/radar"        # where helpers + filled prompts live inside the sandbox

echo "==> Sandbox: $SANDBOX   Radar dir: $RADAR   TZ: $TZ_CRON"
for f in notion-bootstrap.mjs gw-cron.sh grant-cron-admin.py \
         prompts/conf-radar.md prompts/topic-trends.md prompts/weekly-digest.md; do
  [ -f "$RADAR/$f" ] || { echo "ERROR: $RADAR/$f missing." >&2; exit 1; }
done
: "${NOTION_TOKEN:?Set NOTION_TOKEN (host) — the bootstrap creates/patches Notion DBs directly.}"

CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
[ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (run ./setup-finn.sh)." >&2; exit 1; }
echo "==> Container: $CONTAINER"
dx0()  { docker exec -u 0 "$CONTAINER" "$@"; }                       # as root (nsenter/grant/restart)
dx998(){ docker exec -u 998 -e HOME=/sandbox "$CONTAINER" "$@"; }    # as the sandbox user
gw()   { dx0 "$SBX_RADAR/gw-cron.sh" "$@"; }                         # openclaw, inside the gateway netns

# --- 1. Bootstrap Notion (HOST-side) ------------------------------------------------------------
echo "==> Bootstrapping Notion (extend existing event-intel DBs; create trend DBs; seed)…"
BOOT_JSON="$(NOTION_TOKEN="$NOTION_TOKEN" node "$RADAR/notion-bootstrap.mjs")"
echo "    $BOOT_JSON"
get() { printf '%s' "$BOOT_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1',''))"; }
EVENTS_DB="$(get events_db)"; SPEAKERS_DB="$(get speakers_db)"; TOPICS_DB="$(get topics_db)"; TRENDS_DB="$(get trends_db)"
[ -n "$EVENTS_DB" ] && [ -n "$TOPICS_DB" ] && [ -n "$TRENDS_DB" ] || { echo "ERROR: bootstrap returned no DB ids." >&2; exit 1; }

# --- 2. Resolve Victor's Telegram chat id (for --announce delivery) ------------------------------
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT_ID" ]; then
  CHAT_ID="$(dx0 sh -c "grep -oiE 'chat[_ ]?id[\"= :]+-?[0-9]{6,}' /tmp/gateway.log 2>/dev/null | grep -oE '\-?[0-9]{6,}' | tail -1" || true)"
fi
if [ -n "$CHAT_ID" ]; then echo "==> Telegram chat id: $CHAT_ID"; else
  echo "    WARNING: no Telegram chat id auto-detected. DM finn once, then re-run with TELEGRAM_CHAT_ID=<id>." >&2
  echo "    Registering with last-channel delivery fallback for now." >&2
fi

# --- 3. Install the netns + admin helpers into the sandbox --------------------------------------
echo "==> Installing radar helpers into $SBX_RADAR …"
dx998 mkdir -p "$SBX_RADAR"
docker cp "$RADAR/gw-cron.sh"         "$CONTAINER:$SBX_RADAR/gw-cron.sh"
docker cp "$RADAR/grant-cron-admin.py" "$CONTAINER:$SBX_RADAR/grant-cron-admin.py"
dx0 sh -c "chown 998:998 $SBX_RADAR/gw-cron.sh $SBX_RADAR/grant-cron-admin.py && chmod 755 $SBX_RADAR/gw-cron.sh"

# --- 4. Grant operator.admin (idempotent); restart the gateway only if it changed ---------------
echo "==> Ensuring the CLI device has operator.admin (needed for cron add)…"
GRANT="$(dx998 python3 "$SBX_RADAR/grant-cron-admin.py" | tail -1)"
echo "    grant: $GRANT"
if [ "$GRANT" = "CHANGED" ]; then
  echo "==> Restarting the gateway to reload the device table…"
  before="$(dx0 sh -c 'wc -l < /tmp/gateway.log 2>/dev/null' | tr -d '[:space:]')"
  dx0 sh -c '
    GWPID=$(for p in $(pgrep -x openclaw); do pp=$(awk "{print \$4}" /proc/$p/stat); tr "\0" " " </proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }; done)
    [ -n "$GWPID" ] && kill -TERM "$GWPID"'
  echo "    waiting for the gateway to come back…"
  dx0 sh -c "timeout 90 sh -c 'until tail -n +$(( ${before:-0} + 1 )) /tmp/gateway.log 2>/dev/null | grep -qiE \"http server listening|\\[gateway\\] ready\"; do sleep 2; done'" \
    && echo "    gateway back up." || echo "    WARNING: did not see a fresh ready line; continuing (it may still be coming up)."
fi

# --- 5. Stage the filled prompts as files in the sandbox ----------------------------------------
# (Pass the 3KB+ prompts as files read via $(cat) at registration — avoids quoting them through
#  the docker→nsenter→runuser layers.)
fill_stage() {  # $1 = prompt basename (without .md) -> stages $SBX_RADAR/$1.msg
  local f="$RADAR/prompts/$1.md" tmp; tmp="$(mktemp)"
  sed -e "s|{{EVENTS_DB}}|$EVENTS_DB|g" -e "s|{{SPEAKERS_DB}}|$SPEAKERS_DB|g" \
      -e "s|{{TOPICS_DB}}|$TOPICS_DB|g" -e "s|{{TRENDS_DB}}|$TRENDS_DB|g" \
      -e "s|{{CHAT_ID}}|$CHAT_ID|g" "$f" > "$tmp"
  docker cp "$tmp" "$CONTAINER:$SBX_RADAR/$1.msg"
  dx0 sh -c "chown 998:998 $SBX_RADAR/$1.msg"
  rm -f "$tmp"
}
echo "==> Staging filled prompts…"
fill_stage conf-radar; fill_stage topic-trends; fill_stage weekly-digest

# --- 6. Register the three cron jobs (idempotent: remove same-named, then add) -------------------
rm_by_name() {  # $1 = job name
  local ids
  ids="$(gw cron list --json 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print('\n'.join(j.get('id','') for j in d.get('jobs',[]) if j.get('name')=='$1'))" 2>/dev/null || true)"
  for id in $ids; do [ -n "$id" ] && gw cron rm "$id" >/dev/null 2>&1 || true; done
}
add_job() {  # $1=job-name  $2=cron-expr  $3=flags(string)  $4=prompt-basename (the staged .msg)
  rm_by_name "$1"
  echo "==> Registering: $1  ($2 $TZ_CRON)"
  local out
  out="$(dx0 sh -c "$SBX_RADAR/gw-cron.sh cron add --name '$1' --cron '$2' --tz '$TZ_CRON' --timeout-seconds '$JOB_TIMEOUT' $3 --message \"\$(cat '$SBX_RADAR/$4.msg')\"" 2>&1 | grep -viE 'qqbot|Config warn')"
  if printf '%s' "$out" | grep -q '"id":'; then echo "    ok"; else
    echo "    ERROR registering $1:" >&2; printf '%s\n' "$out" | tail -4 >&2
  fi
}
# Route jobs through the MAIN agent (a dedicated session-key per job) — NOT --session isolated.
# Isolated cron sessions are stripped of the workspace bootstrap (AGENTS.md/TOOLS.md), so Nemotron
# never calls tools; under the main agent it gets the tool-use priming and drives tools reliably.
DELIVER="--announce --channel telegram"
[ -n "$CHAT_ID" ] && DELIVER="$DELIVER --to $CHAT_ID"

# Stagger the two morning jobs 1h apart: conf-radar (daily) at 09:00, weekly-digest at 10:00.
# They previously BOTH fired at 09:00 on Mondays — bursting two agentic loops into the shared
# Nemotron worker (32-in-flight cap) tripped "ResourceExhausted: Worker local total request
# limit reached" and killed the digest on its first turn. 10:00 also lets the digest read that
# morning's fresh conf-radar updates instead of racing them.
add_job finn-conf-radar    "0 9 * * *"  "--session-key agent:main:conf-radar $DELIVER"        conf-radar
add_job finn-topic-trends  "0 18 * * 0" "--session-key agent:main:topic-trends --no-deliver"  topic-trends
add_job finn-weekly-digest "0 10 * * 1" "--session-key agent:main:weekly-digest $DELIVER"     weekly-digest

# --- 7. Verify ----------------------------------------------------------------------------------
echo "==> Registered cron jobs:"
gw cron list 2>/dev/null | grep -iE 'finn-(conf-radar|topic-trends|weekly-digest)|^ID|Schedule' | head -10 || gw cron list || true

if [ "${DRYRUN:-0}" = "1" ]; then
  echo "==> DRYRUN: running finn-conf-radar once now (slow — Nemotron, up to a few minutes)…"
  RID="$(gw cron list --json 2>/dev/null | python3 -c "import sys,json;print(next((j['id'] for j in json.load(sys.stdin).get('jobs',[]) if j.get('name')=='finn-conf-radar'),''))" 2>/dev/null || true)"
  [ -n "$RID" ] && { gw cron run "$RID" --wait --wait-timeout 12m --poll-interval 5s || true; echo "--- last run ---"; gw cron runs --id "$RID" --limit 1 || true; }
fi

cat <<EOF

==> Done.
   Jobs:  finn-conf-radar (daily 09:00 $TZ_CRON) · finn-topic-trends (Sun 18:00) · finn-weekly-digest (Mon 10:00)
   State: extended "📅 AI Events — Singapore" (+ Last checked / Next check due / Latest change);
          new "finn · Topics" + "finn · Trend snapshots" under the BD Intelligence Hub;
          12 APAC events seeded as Status=Proposed (review in the Monday digest).
   Inspect / test (don't wait for the schedule):
     docker exec -u 0 $CONTAINER $SBX_RADAR/gw-cron.sh cron list
     docker exec -u 0 $CONTAINER $SBX_RADAR/gw-cron.sh cron run <jobId> --wait --wait-timeout 12m
   Over Telegram: a daily radar line (🟢/🔔) + the Monday digest (📡).
   Re-apply after any full rebuild/onboard (helpers + admin grant + jobs are all re-applied).
EOF
