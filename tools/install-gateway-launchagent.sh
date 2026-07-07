#!/usr/bin/env bash
set -euo pipefail

# tools/install-gateway-launchagent.sh
#
# Installs (or refreshes) a macOS LaunchAgent that keeps the HOST
# openshell-gateway running: starts it at login/boot and relaunches it if it
# ever dies. This closes the failure mode where the gateway — a plain user
# process — dies with a reboot and nothing restarts it, leaving the sandbox
# supervisor crash-looping until someone notices (see docs/LEARNINGS.md §9 and
# the PROGRESS.md 2026-07-06 outage entry: 6 days down, 26,460 container
# restarts).
#
# The agent reproduces the gateway's env-var-driven configuration exactly
# (the binary takes no CLI flags in this topology). Defaults below mirror the
# NemoClaw docker-gateway profile: plaintext HTTP on 127.0.0.1:8080, sqlite
# state under ~/.local/state/nemoclaw/openshell-docker-gateway/. Override any
# of them via environment variables before running.
#
#   ./tools/install-gateway-launchagent.sh            # install + start
#   UNINSTALL=1 ./tools/install-gateway-launchagent.sh  # remove the agent
#
# NOTE: launchd covers login/boot and crash-restart. It does NOT keep the Mac
# awake — a lid-closed sleeping Mac still pauses everything (cron runs
# included); that is a pmset/lid problem, not a launchd one.

LABEL="${LABEL:-com.nemoclaw.openshell-gateway}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GATEWAY_BIN="${GATEWAY_BIN:-/opt/homebrew/bin/openshell-gateway}"

GW_PROFILE="${GW_PROFILE:-nemoclaw}"
GW_PORT="${GW_PORT:-8080}"
GW_BIND="${GW_BIND:-127.0.0.1}"
GW_STATE_DIR="${GW_STATE_DIR:-$HOME/.local/state/nemoclaw/openshell-docker-gateway}"
GW_SUPERVISOR_IMAGE="${GW_SUPERVISOR_IMAGE:-ghcr.io/nvidia/openshell/supervisor:0.0.44}"
GW_DOCKER_NETWORK="${GW_DOCKER_NETWORK:-openshell-docker}"

if [ "${UNINSTALL:-0}" = 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "==> Uninstalled $LABEL (plist removed; gateway process stopped)."
  exit 0
fi

[ -x "$GATEWAY_BIN" ] || { echo "ERROR: $GATEWAY_BIN not found/executable (set GATEWAY_BIN)." >&2; exit 1; }
echo "==> Gateway:  $GATEWAY_BIN ($("$GATEWAY_BIN" --version 2>/dev/null || echo version unknown))"
echo "==> Profile:  $GW_PROFILE  (http://$GW_BIND:$GW_PORT, TLS+auth disabled — loopback only)"
echo "==> State:    $GW_STATE_DIR"
echo "==> Plist:    $PLIST"

mkdir -p "$HOME/Library/LaunchAgents" "$GW_STATE_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$GATEWAY_BIN</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
		<key>OPENSHELL_GATEWAY</key>
		<string>$GW_PROFILE</string>
		<key>OPENSHELL_DRIVERS</key>
		<string>docker</string>
		<key>OPENSHELL_BIND_ADDRESS</key>
		<string>$GW_BIND</string>
		<key>OPENSHELL_SERVER_PORT</key>
		<string>$GW_PORT</string>
		<key>OPENSHELL_SSH_GATEWAY_HOST</key>
		<string>$GW_BIND</string>
		<key>OPENSHELL_SSH_GATEWAY_PORT</key>
		<string>$GW_PORT</string>
		<key>OPENSHELL_DISABLE_TLS</key>
		<string>true</string>
		<key>OPENSHELL_DISABLE_GATEWAY_AUTH</key>
		<string>true</string>
		<key>OPENSHELL_DB_URL</key>
		<string>sqlite:$GW_STATE_DIR/openshell.db</string>
		<key>OPENSHELL_GRPC_ENDPOINT</key>
		<string>http://$GW_BIND:$GW_PORT</string>
		<key>OPENSHELL_DOCKER_NETWORK_NAME</key>
		<string>$GW_DOCKER_NETWORK</string>
		<key>OPENSHELL_DOCKER_SUPERVISOR_IMAGE</key>
		<string>$GW_SUPERVISOR_IMAGE</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$GW_STATE_DIR/launchd.out.log</string>
	<key>StandardErrorPath</key>
	<string>$GW_STATE_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null && echo "==> Plist written + lints clean."

# Replace any previous incarnation of the agent, then take over from an
# unmanaged (nohup/manual) gateway holding the port — launchd can't bind while
# it lives, and two gateways must never share the sqlite state.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
STRAY="$(lsof -nP -tiTCP:"$GW_PORT" -sTCP:LISTEN || true)"
if [ -n "$STRAY" ]; then
  echo "==> Stopping unmanaged gateway on :$GW_PORT (pid $STRAY) — launchd takes over ..."
  kill -TERM $STRAY 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    lsof -nP -tiTCP:"$GW_PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
    sleep 1
  done
fi

echo "==> Loading the agent ..."
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "==> Verifying ..."
ok=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if lsof -nP -tiTCP:"$GW_PORT" -sTCP:LISTEN >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
if [ -n "$ok" ]; then
  NEWPID="$(lsof -nP -tiTCP:"$GW_PORT" -sTCP:LISTEN)"
  echo "    Gateway listening on :$GW_PORT under launchd (pid $NEWPID)."
  launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|pid" | head -3 || true
else
  echo "    ERROR: nothing listening on :$GW_PORT — check $GW_STATE_DIR/launchd.err.log" >&2
  exit 1
fi

# The outgoing gateway `docker stop`s its sandboxes on TERM, and restart policy
# `unless-stopped` will NOT revive an explicitly-stopped container — the new
# gateway then sits in "Sandbox failed to become ready (ContainerExited)"
# forever. Start any exited sandbox containers so their supervisors re-register.
EXITED="$(docker ps -a --filter name='^openshell-' --filter status=exited --format '{{.Names}}' 2>/dev/null || true)"
if [ -n "$EXITED" ]; then
  echo "==> Restarting sandbox container(s) stopped during the takeover:"
  for c in $EXITED; do
    echo "    docker start $c"
    docker start "$c" >/dev/null
  done
fi
echo "    Sandbox supervisors reconnect on their own within ~1 min; then:"
echo "      openshell status   +   a live prompt over Telegram."
