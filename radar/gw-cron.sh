#!/bin/sh
# radar/gw-cron.sh — run an OpenClaw gateway-client command from INSIDE the gateway's
# network namespace, as the sandbox user, with the gateway token.
#
# Why this exists (hard-won, see docs/LEARNINGS.md §7): on the macOS host-process
# topology the gateway runs in its OWN netns, so `openclaw cron` (a live WS client) is
# unreachable from a normal `docker exec` (main netns) — it must originate inside the gateway
# netns via nsenter. This script resolves the live gateway PID (the `openclaw` child of
# `nemoclaw-start`), reads its OPENCLAW_GATEWAY_TOKEN, and execs `openclaw` in that netns as
# uid 998. MUST be run as ROOT inside the sandbox container (nsenter + runuser need it).
#
# Usage (from the host): docker exec -u 0 <container> /sandbox/.cache/radar/gw-cron.sh cron list
set -eu
GWPID=$(for p in $(pgrep -x openclaw 2>/dev/null); do
  pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
  if tr '\0' ' ' < "/proc/$pp/cmdline" 2>/dev/null | grep -q nemoclaw-start; then echo "$p"; break; fi
done)
# Fallback: after `nemoclaw recover` the gateway runs out-of-band (reparented to
# pid 1, no nemoclaw-start). Accept an openclaw process that carries the gateway
# token and is NOT the child of another openclaw (embedded agent runs are).
if [ -z "${GWPID:-}" ]; then
  GWPID=$(for p in $(pgrep -x openclaw 2>/dev/null); do
    pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    case "$(cat "/proc/$pp/comm" 2>/dev/null)" in openclaw*) continue ;; esac
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^OPENCLAW_GATEWAY_TOKEN='; then echo "$p"; break; fi
  done)
fi
[ -n "${GWPID:-}" ] || { echo "gw-cron: gateway process not found (neither nemoclaw-start child nor token-bearing out-of-band worker)" >&2; exit 3; }
TOK=$(tr '\0' '\n' < "/proc/$GWPID/environ" 2>/dev/null | sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' | head -1)
exec nsenter -t "$GWPID" -n -- runuser -u sandbox -- env \
  HOME=/sandbox \
  OPENCLAW_GATEWAY_URL=ws://127.0.0.1:18789 \
  OPENCLAW_GATEWAY_TOKEN="$TOK" \
  /usr/local/bin/openclaw "$@"
