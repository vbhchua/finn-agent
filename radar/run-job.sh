#!/bin/sh
# radar/run-job.sh — run a radar prompt through finn's MAIN agent (full bootstrap → tools work).
#
# Why (hard-won, see docs/LEARNINGS.md §7): a cron job with an `agentTurn` payload runs in a
# STRIPPED context (no workspace bootstrap / tool-use priming), so the weak Nemotron model never
# calls tools — it just echoes templates. The `openclaw agent --agent main` path DOES inject the
# bootstrap (AGENTS.md/TOOLS.md) and the model drives tools reliably (proven: notion__query_database
# called, real data returned). So the radar cron jobs are `--command` type that invoke THIS wrapper,
# which runs `openclaw agent --agent main`.
#
# Runs as a child of the gateway (uid 998, inside the gateway netns). Resolves the gateway token from
# the gateway process env in case the command env is scrubbed. Args: $1 = prompt basename (the staged
# /sandbox/.cache/radar/<name>.msg), $2 = optional Telegram chat id to deliver to (omit = silent).
set -eu
NAME="$1"; CHAT="${2:-}"
MSG="/sandbox/.cache/radar/$NAME.msg"
[ -f "$MSG" ] || { echo "run-job: missing $MSG" >&2; exit 2; }

# Resolve the gateway token (the gateway = the openclaw child of nemoclaw-start).
GWPID=$(for p in $(pgrep -x openclaw 2>/dev/null); do
  pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
  if tr '\0' ' ' < "/proc/$pp/cmdline" 2>/dev/null | grep -q nemoclaw-start; then echo "$p"; break; fi
done)
TOK=$(tr '\0' '\n' < "/proc/${GWPID:-self}/environ" 2>/dev/null | sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' | head -1)

# Deliver to Telegram only when a chat id is given (conf-radar / weekly-digest); silent otherwise.
if [ -n "$CHAT" ]; then set -- --to "$CHAT"; else set -- ; fi

exec env HOME=/sandbox \
  OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789 \
  OPENCLAW_GATEWAY_TOKEN="$TOK" \
  /usr/local/bin/openclaw agent --agent main "$@" --message "$(cat "$MSG")"
