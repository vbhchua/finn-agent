# CLAUDE.md

finn — a sandboxed OpenClaw agent on **NVIDIA NemoClaw / OpenShell** that hunts Singapore AI
events. Setup/run: `README.md` → `SETUP.md`. Security model: `architecture/`. Distilled
gotchas (symptom → root cause → fix): `docs/LEARNINGS.md`. Build log: `PROGRESS.md`.

## Git conventions

- **Conventional Commits v1.0.0** for commits AND PR titles (the PR title becomes the squash subject).
- **Never push to `master` directly** — every change goes through a feature branch + PR, docs included.

## Script & secrets conventions

- `setup-finn.sh` is the single idempotent configurator: it onboards a stock sandbox if missing,
  then applies every layer (Telegram · search · fetch · inference model · calendar + Notion MCPs ·
  radar crons) from `.env`. Each layer runs only if its keys are set; scope with `ONLY=`/`SKIP=`.
  Re-run after any rebuild. (The former `runmod-*.sh` add-ons were folded into it.)
- Runtime add-ons (MCP servers, channels, cron jobs, API keys) live in the container's writable
  layer and are **wiped by any rebuild/re-onboard**; only the baked Telegram token and host-side
  egress policies survive. Re-apply with the scripts — never patch the live container by hand.
- Secrets belong in a gitignored `.env` (template: `.env.sample`) — never in images, configs, or commits.

## Operational hard rules (details in docs/LEARNINGS.md)

- **Never `docker restart` an OpenShell sandbox** — the supervisor comes back as `sleep infinity`
  and the gateway never respawns. Restart = `kill -TERM` the gateway worker (the `openclaw` child
  of `nemoclaw-start`) or `nemoclaw finn rebuild`. (§5)
- **Gateway health is LOG-authoritative** (`/tmp/gateway.log` → `listening` + `ready`); socket
  probes false-negative from the main netns — never auto-kill on a socket check. (§3)
- **After registering/changing an MCP server: full gateway restart** (no `mcp reload` on this
  OpenClaw). The on-disk config key is `mcp.servers`, not `mcpServers`. (§2)
- **`NET:OPEN DENIED <site>` during research is expected** (deny-by-default + server-side fetch);
  do not approve the auto-drafted per-site policy proposals. (§4)
- A `--from` onboard image needs the vendored patch
  `patches/nemoclaw-2026.6.x-chat-send-runid.patch` (upstream NemoClaw ≤ v0.0.68 only covers
  OpenClaw ≤ 2026.6.8). (§8)
- **Any rebuild wipes gateway device pairing** — every `openclaw` CLI call then fails with
  `pairing required` and `nemoclaw finn agent` silently falls back to the embedded path.
  Re-bootstrap with `tools/approve-cli-device.sh`; never trust a PONG that follows an
  `EMBEDDED FALLBACK` line. (§12)

## Verifying a change

After any setup/runmod: container healthy → `openclaw mcp list` shows the expected servers →
a live `web_search` + `web_fetch` **over Telegram** is the final word. Out-of-band probes
(`docker exec`, `diagnostics`) run in the open main netns and can pass while the gateway path
is broken (LEARNINGS §1).
