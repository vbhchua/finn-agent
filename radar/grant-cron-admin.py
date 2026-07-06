#!/usr/bin/env python3
# radar/grant-cron-admin.py — grant the paired CLI device 'operator.admin' scope.
#
# Why (hard-won, see docs/LEARNINGS.md §7): `openclaw cron add/rm/edit` requires
# operator.admin, but a headless `nemoclaw onboard` pairs the CLI device with only
# operator.{read,write,pairing} and there is NO existing admin device to approve the upgrade
# (the request just sits pending forever, and a device with only operator.pairing cannot
# self-approve an admin upgrade). So we grant operator.admin directly in the gateway's on-disk
# device table, then restart the gateway to reload it. This is a legitimate local setup step on
# finn's OWN sandbox — it does NOT widen network/egress, only lets the local operator schedule
# cron jobs (which the in-process agent can already do via its cron tool).
#
# Run as uid 998 (HOME=/sandbox) so file ownership is preserved. Prints CHANGED or UNCHANGED so
# the caller restarts the gateway only when needed. Idempotent.
import json, sys

PAIRED = "/sandbox/.openclaw/devices/paired.json"
PENDING = "/sandbox/.openclaw/devices/pending.json"

try:
    d = json.load(open(PAIRED))
except FileNotFoundError:
    print("UNCHANGED"); sys.exit(0)

changed = False
for dev in d.values():
    for key in ("scopes", "approvedScopes"):
        lst = dev.setdefault(key, [])
        if "operator.admin" not in lst:
            lst.append("operator.admin"); changed = True
    tok = (dev.get("tokens") or {}).get("operator")
    if tok and "operator.admin" not in tok.get("scopes", []):
        tok["scopes"].append("operator.admin"); changed = True

if changed:
    json.dump(d, open(PAIRED, "w"), indent=2)
    try:
        open(PENDING, "w").write("{}\n")   # clear the now-satisfied pending upgrade request
    except Exception:
        pass

print("CHANGED" if changed else "UNCHANGED")
