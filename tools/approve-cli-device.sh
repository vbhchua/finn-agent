#!/bin/sh
# tools/approve-cli-device.sh — bootstrap gateway device pairing for the sandbox's
# own CLI after a rebuild/recreate wiped devices/paired.json (LEARNINGS §12).
#
# Why this exists:
#   - Every rebuild wipes the gateway's device table; with nothing paired, every
#     gateway CLI call fails with "pairing required" and nemoclaw-start's auto-pair
#     watcher (the sanctioned approver) is itself locked out — it can't bootstrap
#     the FIRST device.
#   - `openclaw devices approve <id>` can't converge for a first-time pairing: each
#     invocation makes two gateway connects requesting different scope sets, and
#     each connect replaces the pending request with a fresh id.
#   - A workspace restore may plant a CORRUPT identity (rebuild-backups strip
#     private keys) — openclaw then silently generates a throwaway identity per run
#     and floods pending.json. We detect that and regenerate the identity first.
#
# So: validate (and if broken, regenerate) the persistent CLI identity, register a
# pairing request, then approve it by calling OpenClaw's own approveDevicePairing()
# directly on the on-disk store. Idempotent; run as the host user (needs nemoclaw).
#
# Usage: SANDBOX=finn ./tools/approve-cli-device.sh
set -eu
SANDBOX="${SANDBOX:-finn}"
OC_DIST=/usr/local/lib/node_modules/openclaw/dist

echo "==> Checking the persistent CLI identity ..."
if ! nemoclaw "$SANDBOX" exec -- node -e 'const fs=require("fs"),c=require("crypto");const d=JSON.parse(fs.readFileSync("/sandbox/.openclaw/identity/device.json","utf8"));const sig=c.sign(null,Buffer.from("x"),c.createPrivateKey(d.privateKeyPem));process.exit(c.verify(null,Buffer.from("x"),c.createPublicKey(d.publicKeyPem),sig)?0:1)' >/dev/null 2>&1; then
  echo "    identity missing/corrupt (restored from a key-stripped backup?) — regenerating."
  nemoclaw "$SANDBOX" exec -- rm -f /sandbox/.openclaw/identity/device.json /sandbox/.openclaw/identity/device-auth.json
else
  echo "    identity key pair is valid."
fi

echo "==> Registering a pairing request (any gateway CLI call does this) ..."
nemoclaw "$SANDBOX" exec -- openclaw devices list >/dev/null 2>&1 || true

echo "==> Approving the pending request for the current identity ..."
nemoclaw "$SANDBOX" exec -- node -e 'Promise.all([import("fs"),import("'"$OC_DIST"'/device-pairing-C4Uu7tKB.js")]).then(async ([fs,m]) => { const own = JSON.parse(fs.readFileSync("/sandbox/.openclaw/identity/device.json","utf8")).deviceId; const l = await m.l(); if (l.paired.some(d=>d.deviceId===own)) { console.log("    already paired:", own.slice(0,16)); return; } const p = l.pending.filter(r=>r.deviceId===own).sort((a,b)=>b.ts-a.ts)[0]; if (!p) { console.log("    no pending request for the current identity (they expire in 5 min) — rerun"); process.exit(1); } const r = await m.n(p.requestId, {callerScopes:["operator.admin"]}); if (r?.status !== "approved") { console.log("    approve failed:", JSON.stringify(r)); process.exit(1); } console.log("    approved", r.device.deviceId.slice(0,16), "roles:", r.device.roles.join(","), "scopes:", r.device.approvedScopes.join(",")); })' 2>&1 | grep -v -e UNDICI -e trace-warnings

echo "==> Done. The auto-pair watcher can now handle later scope upgrades;"
echo "    run ./setup-finn.sh (radar layer) to top up operator.admin for cron."
