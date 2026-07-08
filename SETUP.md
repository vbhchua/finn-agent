# finn — Setup & Troubleshooting

Companion to the **[README](README.md)** (which has the golden path in *Quick Setup*). This guide
has the full walkthrough: the OpenClaw 2026.6.10 build, what `setup-finn.sh` does, the **Exa**
search variant, the **calendar / Notion / radar** MCP add-ons in depth, manual steps, and
**troubleshooting**.

---

## Setup

> **The live finn runs OpenClaw 2026.6.10 / nemoclaw v0.0.68 (since 2026-06-27) — the README's
> golden path.** Onboard with `nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn`,
> then `./setup-finn.sh`. On 2026.6.x, **firecrawl/exa are un-bundled** (an installed plugin,
> baked at build — `setup-finn.sh` handles both eras), and the one-time base build needs
> **NemoClaw v0.0.68** + the vendored patch
> `patches/nemoclaw-2026.6.x-chat-send-runid.patch` (upstream ≤ v0.0.68 only covers OpenClaw
> ≤ 2026.6.8). See PROGRESS.md "OpenClaw 2026.6.10 upgrade" for the full story. The plain
> 2026.5.x stock onboard below is kept as the **minimal search-only variant**.

> **What changed since v0.0.55 (read first).** finn used to be the **full NemoClaw
> production image** built locally (`finn-base:local`) with a Firecrawl layer baked on
> top, driven by a ~9-step script — because the old community base shipped no
> `nemoclaw-start` and its gateway couldn't authenticate. **On v0.0.67 almost all of
> that is gone:**
>
> - The **stock base now ships `nemoclaw-start`**, so a plain `nemoclaw onboard --name finn`
>   gives a working, authenticating gateway. **No custom Dockerfile, no `finn-base:local`.**
> - **Web search works out of the box** — provider `brave`, `BRAVE_API_KEY` auto-injected
>   by onboard (verified end-to-end).
> - The old manual fixes are now **defaults**: `proxy.loopbackMode=gateway-only`,
>   `gateway.mode=local`, `tools.toolSearch=false` (applied for Nemotron via a model
>   manifest), and `tools.codeMode` off.
> - `firecrawl` / `exa` / `tavily` / … are **bundled stock extensions** (just disabled) **on
>   OpenClaw ≤2026.5.x**, so adding full-page fetch is one config flag — no plugin install. (⚠️
>   **2026.6.x un-bundles them** → installed plugin; see the upgrade note above. No openclaw upgrade
>   needed for the v0.0.67 live setup.)
> - **Telegram is a first-class command**: `nemoclaw finn channels add telegram`.
>
> The retired custom-image machinery (the v0.0.55 era) is preserved in git history, and the
> distilled gotchas live in [docs/LEARNINGS.md](docs/LEARNINGS.md). This guide documents the **current** setup in full; the README has the fast path.

## Quick start

The golden path (what finn actually runs — same as the README's Quick Setup):

```bash
set -a; . ./.env; set +a                  # secrets from the gitignored .env (.env.sample = template)

# 0. One-time per host — build the local base image step 1 builds FROM (idempotent;
#    skips if present). Skipping it on a fresh host makes step 1 fail with
#    "pull access denied for nemoclaw-finn-base" — see the "base image" section below:
./tools/build-finn-base.sh

# 1. Create the sandbox — the OpenClaw 2026.6.10 image (FROM the base built in step 0):
nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn

# 2. Configure everything from .env in one idempotent pass: Telegram, Brave search,
#    Firecrawl fetch, the inference model (compatible-endpoint primary + optional
#    OpenRouter fallback), the calendar + Notion MCPs, and the radar cron loops.
#    Each layer runs only if its keys are in .env; safe to re-run after any rebuild.
NOTION_WRITE=1 MS_CALENDAR_WRITE=1 ./setup-finn.sh   # drop the *_WRITE flags for read-only MCPs
#    DRYRUN=1 ./setup-finn.sh          # also runs conf-radar once (~minutes)
#    ONLY='models' ./setup-finn.sh     # re-apply just one layer (models|calendar|notion|radar|search|fetch|telegram)
```

**Minimal search-only variant:** a stock `nemoclaw onboard --name finn` (no `--from`) is a
working agent by itself — gateway + brave web search, OpenClaw 2026.5.x era. `setup-finn.sh`
adds the two things that aren't out-of-the-box on either path: full-page **fetch** via
Firecrawl, and the **Telegram** channel.

### One-time: build the 2026.6.10 base image

`Dockerfile.finn-2026.6.10` builds `FROM nemoclaw-finn-base:2026.6.10` — a **local-only** image
(never in a registry). It must exist locally **before** `nemoclaw onboard --from …`, or Docker
treats the tag as a registry ref and the onboard fails with `pull access denied for
nemoclaw-finn-base, repository does not exist`. That error means "you skipped this step."

**Recommended — one idempotent command** (skips if the image is already present; `FORCE=1`
rebuilds):

```bash
./tools/build-finn-base.sh
```

It runs exactly the steps below: build once from a **NemoClaw v0.0.68** checkout — **pin the
tag**; the combination is verified against v0.0.68 exactly
([tags](https://github.com/NVIDIA/NemoClaw/tags)). NemoClaw's bundled patches only cover
OpenClaw ≤ 2026.6.8 (2026.6.9 changed the chat-send run-id callsite), so it applies the vendored
1-line tolerance first:

```bash
git clone --branch v0.0.68 --depth 1 https://github.com/NVIDIA/NemoClaw.git && cd NemoClaw
git apply <this-repo>/patches/nemoclaw-2026.6.x-chat-send-runid.patch
docker build -t nemoclaw-finn-base:2026.6.10 \
  --build-arg OPENCLAW_VERSION=2026.6.10 \
  --build-arg NEMOCLAW_WEB_SEARCH_ENABLED=1 \
  -f Dockerfile .
```

#### Fresh host / new EC2

- **Order matters:** run `./tools/build-finn-base.sh` (or the manual build) **before**
  `nemoclaw onboard`. The base build needs outbound HTTPS (GitHub + ghcr + npm) and ~15–20 GB
  free disk.
- **Build natively — don't ship the image across architectures.** The image built on Apple
  Silicon is `linux/arm64`; a `docker save | docker load` onto an **x86_64** EC2 (c5/m5/g5/…)
  won't run. Build on the target host (or on a machine of the same arch). finn needs no GPU —
  inference is remote (the Kimi/Moonshot compatible-endpoint), so a general-purpose instance is
  fine.
- **Reuse across instances via a registry (e.g. ECR).** `nemoclaw onboard` has **no
  `--build-arg`**, so you can't repoint `BASE_IMAGE` at onboard time — instead make the tag
  resolve locally by pulling and re-tagging:

  ```bash
  docker pull <acct>.dkr.ecr.<region>.amazonaws.com/nemoclaw-finn-base:2026.6.10
  docker tag  <acct>.dkr.ecr.<region>.amazonaws.com/nemoclaw-finn-base:2026.6.10 \
              nemoclaw-finn-base:2026.6.10
  nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn
  ```

  Push the image (built for the instance's arch) to ECR once; every new host then pulls instead
  of rebuilding NemoClaw from source. (Alternatively, edit the `ARG BASE_IMAGE` default in
  `Dockerfile.finn-2026.6.10` to the ECR URI.)

The host CLI must match too: `setup-finn.sh` preflights `nemoclaw --version` — it aborts on
anything older than v0.0.68 (no 2026.6.x patch support) and warns-but-continues on anything
newer (untested; if upstream now covers OpenClaw ≥ 2026.6.9, drop the vendored patch).
`NEMOCLAW_VERSION_SKIP_CHECK=1` bypasses the check.

Full rationale (why firecrawl is baked at build on 2026.6.x, why the entrypoint is inherited)
is in the `Dockerfile.finn-2026.6.10` header; drop the patch once upstream NemoClaw covers
OpenClaw ≥ 2026.6.9.

`setup-finn.sh` (idempotent) does, in order:
1. Ensures the sandbox exists (stock `nemoclaw onboard --name finn` if missing).
2. Adds the **Telegram** channel (`nemoclaw finn channels add telegram` — interactive;
   it prompts for the token and **rebuilds** to bake it). Skipped if already enabled.
3. Enables the **bundled Firecrawl** extension for `web_fetch` (search stays on `brave`):
   activates the `firecrawl` egress policy, sets
   `tools.web.fetch.provider=firecrawl` + `plugins.entries.firecrawl.enabled=true`,
   injects `FIRECRAWL_API_KEY` into the plugin config, and adds the `/etc/hosts` alias the
   plugin's SSRF precheck needs. Skipped if `FIRECRAWL_API_KEY` is unset.
4. Restarts the gateway and prints a config + policy snapshot.

**Why search and fetch are split.** `brave` returns search results/snippets out of the box.
Reading a *whole page* still needs a server-side fetcher, because deny-by-default egress
blocks the agent from hitting arbitrary sites directly — Firecrawl scrapes the page through
its single allow-listed endpoint (`api.firecrawl.dev`), so you never have to allow-list
every site the agent wants to read.

---

## Model providers: Kimi K2.6 primary + OpenRouter fallback

finn's inference is **provider-swappable without touching the sandbox's security posture**.
The sandbox always calls the managed `https://inference.local/v1` route; what answers is
decided host-side:

- **Primary — Kimi K2.6 (Moonshot AI)** through the HOST gateway's `compatible-endpoint`
  provider, which forwards to `https://api.moonshot.ai/v1`. The provider is registered at
  `nemoclaw onboard` (pick *"Other OpenAI-compatible endpoint"*, paste `MOONSHOT_API_KEY`) —
  the key lives gateway-side only; the sandbox config keeps the non-secret
  `apiKey: "unused"` placeholder, which NemoClaw's onboarding smoke check asserts.
- **Fallback — OpenRouter (optional)** via OpenClaw's **built-in** openrouter provider:
  `OPENROUTER_API_KEY` in the config env + `openrouter/<author>/<slug>` model refs (no
  `models.providers` block needed). This is a *direct* call from the gateway netns, so it
  needs the `fixes/openrouter.yaml` egress preset. Default fallback model:
  `openrouter/moonshotai/kimi-k2.6` — the same model over an independent route.

`ONLY='models' ./setup-finn.sh` applies all of it idempotently: activates the openrouter egress
preset, rewrites the sandbox model block (`agents.defaults.model.primary` →
`inference/kimi-k2.6`, model entry, env key + fallbacks when `OPENROUTER_API_KEY` is set),
TERM-restarts the gateway, and verifies with a PONG probe from the gateway netns. Override
knobs: `KIMI_MODEL`, `KIMI_CONTEXT_WINDOW`, `KIMI_MAX_TOKENS`, `OPENROUTER_MODEL`.

Two traps to know (details: [docs/LEARNINGS.md](docs/LEARNINGS.md) §4 + §6):

- **A resumed onboard skips the OpenClaw config step**, leaving the old model pinned — the
  compatible-endpoint smoke check then fails with *"agents.defaults.model.primary is '…';
  expected 'inference/<model>'"*. Run `ONLY='models' ./setup-finn.sh`, then re-run the onboard.
- **Egress policies enforce `binaries`** — probing `openrouter.ai` with curl returns
  *"CONNECT tunnel failed, response 403"* even when the policy is live; probe with
  `/usr/local/bin/node` (the binary the real traffic uses).

## Variant: Exa search instead of Brave

`exa` is also a **bundled** extension. To use Exa for `web_search` instead of Brave (Firecrawl
still handles `web_fetch`), enable it and point search at it — no install needed:

```bash
export EXA_API_KEY="exa_..."
nemoclaw finn exec -- bash -c 'HOME=/sandbox openclaw config set plugins.entries.exa.enabled true; HOME=/sandbox openclaw config set tools.web.search.provider exa; HOME=/sandbox openclaw config set plugins.entries.exa.config.webSearch.apiKey "'$EXA_API_KEY'"'
nemoclaw finn policy-add exa --yes      # fixes/exa.yaml → api.exa.ai ; also add the /etc/hosts alias
nemoclaw finn recover
```

> **Exa content extraction is a per-call tool parameter, not config.** The only valid keys
> under `plugins.entries.exa.config.webSearch` are `apiKey` and `baseUrl`; setting
> `…webSearch.contents.text` is **rejected** (`must not have additional properties:
> "contents"`). Full text comes from `web_search({ query, contents: { text: true } })` at call
> time (the default is highlights) — or just use Firecrawl `web_fetch`.

---

## Add-on: Outlook / live.com calendar (via MCP)

Gives the agent **Microsoft Outlook / Microsoft 365 calendar** access through a zero-dependency
**Microsoft Graph MCP server** (`mcp/ms-calendar-mcp.mjs`). There is **no built-in** Outlook/Graph
tool in NemoClaw, so this stays custom. It's an **additive runtime capability** layered on a
running `finn` — it does **not** rebuild the image and re-applies like the Firecrawl / `/etc/hosts`
steps.

- **Read-only by default** (5 tools): `list_events`, `get_event`, `list_calendars`, `whoami`,
  `diagnostics`.
- **Read/write is an explicit opt-in** (`MS_CALENDAR_WRITE=1`, +3 tools): `create_event`,
  `update_event`, `delete_event`. Off by default because the agent reads arbitrary web pages, and
  `delete_event` is irreversible — see [architecture §4 item 6](architecture/04-add-on-security.md).

Built for a **personal Microsoft account** (`live.com` / `outlook.com`). Personal accounts can't
use app-only client credentials, so it authenticates with a **delegated OAuth refresh token** you
mint once on your laptop and inject like the Firecrawl key.

### One-time setup

1. **Register a free Entra app** (no tenant admin needed) and grant delegated **`User.Read`,
   `offline_access`**, plus **`Calendars.ReadWrite`** (read+write) *or* `Calendars.Read` (read-only);
   under *Authentication* enable **"Allow public client flows"**. Full click-path is in the header of
   `tools/ms-graph-login.mjs`.
2. **Mint a refresh token on your laptop** (device-code flow — opens a URL, you sign in as your
   live.com user; defaults to the `ReadWrite` scope):
   ```bash
   node tools/ms-graph-login.mjs <CLIENT_ID>
   ```
3. **Inject + wire it into finn:**
   ```bash
   export MS_CALENDAR_CLIENT_ID='<app client id>'
   export MS_CALENDAR_REFRESH_TOKEN='<token printed by step 2>'
   ONLY='calendar' ./setup-finn.sh                       # read-only
   MS_CALENDAR_WRITE=1 ONLY='calendar' ./setup-finn.sh    # read/write (create/update/delete)
   ```

`setup-finn.sh`'s calendar layer applies the **`ms-calendar`** network policy (`fixes/ms-calendar.yaml` →
`graph.microsoft.com` + `login.microsoftonline.com` only), installs the MCP server at
`/sandbox/mcp/`, writes credentials to a sandbox-only `0600` file
(`/sandbox/.config/ms-calendar.env`, **not** `openclaw.json`), registers the server with
`openclaw mcp set`, and restarts the gateway. Run it **without** the two `MS_CALENDAR_*` vars to
wire everything up and validate egress first — the calendar tools stay inactive until you inject a
token. (The read-vs-write guard is the **OAuth scope** + tool gating, not the egress policy — a
`Calendars.Read` token gets `403` from Graph on any write even though the policy allows the method.)

> **Why a custom policy instead of the built-in `outlook` preset?** The built-in `outlook` preset
> allows `graph.microsoft.com` GET/POST/PATCH — but **not DELETE**, so `delete_event` would be
> blocked in write mode. `fixes/ms-calendar.yaml` is a tighter, calendar-only subset that also
> allows DELETE. For **read-only** you can skip the custom file and just
> `nemoclaw finn policy-add outlook --yes`.

> **No `/etc/hosts` hack needed (unlike Firecrawl).** The server uses plain `fetch()` and never runs
> a `dns.lookup` SSRF precheck (Firecrawl's plugin does — that's the only reason Firecrawl needs the
> hosts alias). It does, however, need the gateway's proxy + CA re-supplied to its subprocess — the
> server self-bootstraps that (see the "egress trap" entry below).

Verify (OpenClaw 2026.5.x — the stock onboard — has no `mcp probe`; use `mcp list` + the server's own
`diagnostics`):
```bash
nemoclaw finn exec -- openclaw mcp list      # → lists "ms-calendar"
# functional check (egress + auth), run as the sandbox user:
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}' | head -1)
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}' \
  | docker exec -i -u 998 -e HOME=/sandbox "$cid" node /sandbox/mcp/ms-calendar-mcp.mjs 2>/dev/null
# → read-only exposes 5 tools, read/write 8; diagnostics reports egress + token refresh.
```
then over Telegram: *"what's on my calendar this week"* — and, in write mode, *"add a 3pm meeting
tomorrow called Sync"* / *"delete that event."* If a calendar tool errors, ask the agent to run
**`diagnostics`** first — it self-tests credential presence, read/write mode, network egress to
Microsoft, and token refresh.

---

## Add-on: Notion (via MCP)

Gives the agent **Notion** access through a second zero-dependency stdio MCP server
(`mcp/notion-mcp.mjs`) that calls the Notion REST API (`api.notion.com`) with a Notion **internal
integration token**. Notion's *hosted* MCP (`mcp.notion.com`) is OAuth-only with a human browser
flow, so it can't drive a headless sandbox — hence the local-server + token model. Same scaffolding
as the calendar add-on (the EGRESS-TRAP re-exec, 0600 creds file, full-gateway-restart to rebuild
the MCP runtime).

- **Read-only by default** (7 tools): `search`, `get_page`, `get_page_content`, `get_database`,
  `query_database`, `whoami`, `diagnostics`.
- **Read/write** (`NOTION_WRITE=1`, +3 tools): `create_page`, `update_page`, `append_blocks`.

**One-time setup (in your browser):**
1. Create an internal integration at `https://www.notion.so/profile/integrations`; copy the secret
   (`ntn_…`). For write, give it Insert/Update content capability; for read-only, Read content only.
2. **Share** each page/database you want finn to see *with the integration* (page ··· → Connections).
   The integration sees only what's shared.
3. Run it:
   ```bash
   export NOTION_TOKEN='ntn_...'
   ONLY='notion' ./setup-finn.sh                    # read-only
   NOTION_WRITE=1 ONLY='notion' ./setup-finn.sh     # read/write
   ```

`setup-finn.sh`'s notion layer applies the **`notion`** network policy (`fixes/notion.yaml` →
`api.notion.com` GET/POST/PATCH), installs the server, writes the token to `/sandbox/.config/notion.env`
(0600, **not** `openclaw.json`), registers the MCP server, and restarts the gateway to rebuild the MCP
runtime. Run it WITHOUT `NOTION_TOKEN` to wire + validate egress first; the tools stay unauthenticated
until you add a token. Verify:
```bash
nemoclaw finn exec -- openclaw mcp list      # → lists "notion"  (this OpenClaw has no `mcp probe`)
```
then over Telegram: *"search my Notion for <topic>"* / *"what's in my <database> database"* — and in
write mode, *"add a page titled X under <page> with this note."* If a Notion tool errors, ask the
agent to run **`diagnostics`** (token presence, mode, egress, auth). 403 = the integration wasn't
shared on that page (or lacks write capability).

---

## Add-on: Conference Radar + Topic-Trend loops (Features 4 & 5)

finn's **proactive** layer — three **gateway cron jobs** that run scheduled agent turns, research the
web, update **Notion**, and push to **Telegram**. Builds ON TOP of the **event-intelligence** Notion
(the `📅 AI Events — Singapore` + `🎤 Speakers — AI Events SG` DBs). Needs the Notion connector
(above) and the same `NOTION_TOKEN`.

```bash
export NOTION_TOKEN='ntn_...'
ONLY='radar' ./setup-finn.sh        # bootstrap Notion + register the 3 cron jobs
DRYRUN=1 ONLY='radar' ./setup-finn.sh   # ...and run conf-radar once now (~minutes)
```

What it sets up:
- **`finn-conf-radar`** (daily 09:00 SGT) — re-checks UPCOMING events on an adaptive cadence
  (tighter as the event nears), updates the events DB, Telegram-pings on a material change
  (1-line `🟢`/`🔔` heartbeat each run).
- **`finn-topic-trends`** (daily 09:30 SGT, silent) — snapshots the **two least-recently-refreshed**
  watch-topics into `finn · Trend snapshots` (rotation cursor: Topics.`Last snapshot`; the full
  watchlist turns over ≈ weekly). Sharded two-per-run so each run stays inside the 900s job
  budget and a small context even at shared-endpoint peak load.
- **`finn-weekly-digest`** (Mon 10:00 SGT) — the one routine Telegram message: upcoming-soon,
  this-week's updates, trend movers, finn's `Proposed` events.

The radar layer (idempotent) **bootstraps Notion host-side** (`radar/notion-bootstrap.mjs`: extends the
events DB in place with `Last checked`/`Next check due`/`Latest change`, creates `finn · Topics` +
`finn · Trend snapshots` under the hub, seeds topics + the trend baseline + 12 APAC `Proposed`
events), then **grants the gateway `operator.admin`** (`radar/grant-cron-admin.py`) and **registers
cron from inside the gateway netns** (`radar/gw-cron.sh`) — see [docs/LEARNINGS.md](docs/LEARNINGS.md) §7 for *why* those two are
needed on this topology. Inspect / test:
```bash
ctr=$(docker ps --filter name=openshell-finn --format '{{.Names}}' | head -1)
docker exec -u 0 "$ctr" /sandbox/.cache/radar/gw-cron.sh cron list
docker exec -u 0 "$ctr" /sandbox/.cache/radar/gw-cron.sh cron run <jobId> --wait --wait-timeout 12m
```
then over Telegram you'll get the daily radar line + the Monday digest. Re-run `ONLY='radar' ./setup-finn.sh` after any
full rebuild (cron jobs live in the gateway and are lost on a fresh `onboard`).

---

## Manual steps (if you need to run them separately)

### Create / recreate the sandbox

```bash
nemoclaw onboard --name finn          # stock base — gateway + brave search, no custom image
# upgrade an existing sandbox to the current agent version:
nemoclaw finn rebuild
```

### Telegram channel

```bash
export TELEGRAM_BOT_TOKEN="..."
nemoclaw finn channels add telegram   # interactive: prompts for token, then rebuilds to bake it
# after restart: DM the bot, then approve the pairing:
nemoclaw finn exec -- openclaw pairing list telegram
nemoclaw finn exec -- openclaw pairing approve telegram <CODE>     # codes expire in ~1h
```

`channels add` bakes the token into the image at rebuild (it never sits in clear text at runtime).
**Only one sandbox may poll a given bot token** — if two sandboxes share the bot you'll get a
Telegram `409` conflict; stop one with `nemoclaw <other> channels stop telegram`.

### Full-page fetch — Firecrawl (runtime, no image)

```bash
# 1. register + activate the egress policy (api.firecrawl.dev)
cp ./fixes/firecrawl.yaml "$(npm root -g)/nemoclaw/nemoclaw-blueprint/policies/presets/"
nemoclaw finn policy-add firecrawl --yes          # activate BY NAME (--from-file collides; see below)
# 2. enable the bundled extension + point web_fetch at it (search stays brave)
nemoclaw finn exec -- bash -c 'HOME=/sandbox openclaw config set plugins.entries.firecrawl.enabled true; HOME=/sandbox openclaw config set tools.web.fetch.provider firecrawl'
# 3. inject the key into the plugin config (env is only a fallback)
export FIRECRAWL_API_KEY="fc-..."
nemoclaw finn exec -- bash -c "HOME=/sandbox openclaw config set plugins.entries.firecrawl.config.webFetch.apiKey '$FIRECRAWL_API_KEY'"
# 4. /etc/hosts alias for the plugin's SSRF precheck (any public IP; the real request still proxies)
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}')
docker exec -u 0 "$cid" sh -c 'grep -q api.firecrawl.dev /etc/hosts || echo "35.245.250.27 api.firecrawl.dev" >> /etc/hosts'
nemoclaw finn recover
```

`setup-finn.sh` does all four automatically. The key lives in the sandbox's `openclaw.json` (not the
image/repo), so **re-apply after a full rebuild** (the rebuild also regenerates `/etc/hosts`).

---

## Verify inside the sandbox

```bash
nemoclaw finn connect
nemoclaw finn exec -- bash -c 'HOME=/sandbox openclaw config get tools.web.search.provider'  # → brave
nemoclaw finn exec -- bash -c 'HOME=/sandbox openclaw config get tools.web.fetch.provider'   # → firecrawl (if added)
nemoclaw finn exec -- bash -c 'HOME=/sandbox openclaw config get proxy.loopbackMode'         # → gateway-only (default)
```

Functional self-test (search runs through brave with nothing configured):

```bash
nemoclaw finn agent --agent main -m "use web_search to find nvidia.com and report the URL"
```

---

## Sandbox lifecycle

```bash
nemoclaw finn connect      # reconnect / fix broken port-forward
nemoclaw finn status       # health check
nemoclaw finn rebuild      # upgrade sandbox to current agent version
nemoclaw finn recover      # restart the gateway in place
nemoclaw finn destroy      # tear down (workspace state is backed up first)
```

---

## Troubleshooting

### `provider profile import failed: custom provider profile 'brave' already exists`
Seen when re-running setup/onboard. Benign — a prior onboard already registered the `brave`
provider **profile** (template) and the working **instance** `finn-brave-search` (holds
`BRAVE_API_KEY`); search still works. OpenShell's `provider profile import` has no `--force`,
so it refuses to re-import. Fix: delete the stale custom *template* (the instance is a separate
object and is unaffected), then re-run:
```bash
openshell provider profile delete brave    # only deletes the custom template
./setup-finn.sh                             # re-imports brave cleanly (setup-finn.sh also guards this automatically)
```
`setup-finn.sh` now clears a lingering `brave` profile before `nemoclaw onboard`, so a clean
re-run won't trip on it. (If the onboard otherwise completed, you can just ignore the error.)

### FYI: `NET:OPEN DENIED … <some-site>` in the logs is normal (not a web-fetch failure)

During research you'll see pairs like this:

```
NET:OPEN DENIED node → onemotoring.lta.gov.sg:443   (not in any policy)
…then…
POST api.firecrawl.dev/v2/scrape   ALLOWED
```

That's the design working: the model tries a **direct** fetch (blocked by deny-by-default), then
falls back to **Firecrawl's `/v2/scrape`**, which fetches the page server-side. Any URL works through
the single `api.firecrawl.dev` endpoint — no per-site allowlist needed. OpenShell also auto-drafts a
policy proposal (`proposals=1`) per denial; **ignore them** unless you specifically want a site
reachable *directly* (which would defeat the single-endpoint design).

### Symptom: web_fetch fails with `getaddrinfo EAI_AGAIN api.firecrawl.dev`

The Firecrawl plugin runs an **SSRF pre-check via `dns.lookup`** of `api.firecrawl.dev`, but the
sandbox's local resolver can't resolve *any* external host (`dns.lookup` of `google.com` also
`EAI_AGAIN`; everything that works goes via the proxy). A raw `fetch` returns 200 (proxy), but the
plugin's `dns.lookup` precheck fails first. Fix = add a **public IP** for `api.firecrawl.dev` to
`/etc/hosts` so the precheck passes (the real request still uses the proxy, so any public IP works):

```bash
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}')
docker exec -u 0 "$cid" sh -c 'grep -q api.firecrawl.dev /etc/hosts || echo "35.245.250.27 api.firecrawl.dev" >> /etc/hosts'
```

`setup-finn.sh` does this automatically. `/etc/hosts` is read live (no restart) and survives an
in-process `recover`, but a full container rebuild regenerates it — re-run the script.
(This is **Firecrawl-specific**: the calendar MCP server uses plain `fetch()` with no precheck, so it
needs no `/etc/hosts` entry.)

### Symptom: web search/fetch says "the sandbox blocks outbound network requests"

The gateway, inference and policy can all be healthy while Firecrawl `web_fetch` still fails — because
the **Firecrawl API key isn't in the sandbox**. NemoClaw only injects credentials for *messaging
channels*, not for a generic key, so the plugin reads its key from `config.webFetch.apiKey` (env is
only a fallback). Set it, then restart:

```bash
export FIRECRAWL_API_KEY="fc-..."
nemoclaw finn exec -- bash -c "HOME=/sandbox openclaw config set plugins.entries.firecrawl.config.webFetch.apiKey '$FIRECRAWL_API_KEY'"
nemoclaw finn recover
```

The key lives in the sandbox's `openclaw.json` (not the image/repo), so **re-apply after any rebuild**.
openclaw stores it redacted (`openclaw config get …apiKey` → `__OPENCLAW_REDACTED__` means it's set).
*(Web **search** via brave needs no key from you — onboard injects `BRAVE_API_KEY`.)*

### Symptom: `policy-add --from-file` says the name collides

```
Preset name 'firecrawl' collides with a built-in preset. Rename 'preset.name' …
```

Once `fixes/firecrawl.yaml` has been copied into the blueprint presets dir it's a **registered**
preset, so loading it again from a file is refused. Activate it **by name** instead (`policy-list`
shows it as `○ firecrawl`):

```bash
nemoclaw finn policy-add firecrawl --yes      # activate the registered preset
nemoclaw finn policy-list                     # ● firecrawl = applied
```

Re-copy `fixes/firecrawl.yaml` into the blueprint after editing it, or the activated policy keeps the
old contents. (Alternatively: don't copy to the blueprint and give the preset a unique `preset.name`,
then `--from-file` works.)

### Symptom: `doctor` flags `openshell-cluster-nemoclaw not found`

On **macOS** the OpenShell gateway runs as a **host process** (`/opt/homebrew/bin/openshell-gateway`,
supervised by `nemoclaw`), not a container — confirm with `openshell status` (→ `Connected`). `doctor`'s "`[fail]` Docker container:
openshell-cluster-nemoclaw not found" is a topology false-negative for that layout; the gateway is fine.
**Do not** rename the `openshell-finn-<uuid>` container to match — that's the *sandbox*, and its name is
how NemoClaw finds it; renaming orphans every `nemoclaw finn` command.

If `inference.local` doesn't resolve inside the sandbox after a restart (`connect` → "inference.local is
unavailable … DNS proxy not installed"):

```bash
nemoclaw finn exec -- bash -c 'getent hosts inference.local || echo MISSING'
nemoclaw finn recover                                        # usually re-installs it
nemoclaw finn hosts-add inference.local 192.168.65.254       # last resort (host.openshell.internal)
```

### Gateway health: trust the LOG, not a socket probe

The gateway runs in **its own network namespace**, so from a `docker exec` you **cannot** see its
listener — `ss -ltn`, `netstat -ltn`, and even `/proc/net/tcp` all falsely report 18789 "not bound"
while the gateway is perfectly healthy. The only reliable "up" signal is the **gateway log**:

```bash
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}')
docker exec -u 0 "$cid" sh -c 'tail -n 30 /tmp/gateway.log' | grep -iE "http server listening|\[gateway\] ready"
```

A log that simply *stops* is usually **idle** (model calls can be slow — one Nemotron-era call took 141s), not hung. If
it's genuinely stuck, force a relaunch — the `nemoclaw-start` supervisor brings up a fresh gateway:

```bash
docker exec -u 0 "$cid" sh -c 'pkill -TERM -f "openclaw gateway run"'
```

### Symptom: calendar tools fail or are missing

Ask the agent to run the **`diagnostics`** tool (or drive it directly) — it pinpoints which layer:

```bash
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}')
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"diagnostics","arguments":{}}}' \
  | docker exec -i -u 998 -e HOME=/sandbox "$cid" node /sandbox/mcp/ms-calendar-mcp.mjs 2>/dev/null
```

| diagnostics says | Cause | Fix |
|---|---|---|
| `egress …: FAIL …` | `ms-calendar` network policy not applied | `nemoclaw finn policy-add ms-calendar --yes` (re-run `ONLY='calendar' ./setup-finn.sh`) |
| `client_id: MISSING` / `refresh_token: MISSING` | creds file absent (e.g. after a rebuild) | re-run `ONLY='calendar' ./setup-finn.sh` with `MS_CALENDAR_*` exported |
| `token refresh: FAIL … invalid/expired` | refresh token dead (personal-MSA tokens roll if unused ~90d) | re-mint: `node tools/ms-graph-login.mjs <CLIENT_ID>`, re-inject |
| `openclaw mcp list` doesn't show `ms-calendar` | not registered | `openclaw mcp set …` then restart the gateway (the script does both) |
| `diagnostics` shows read-only / no `create_event` | write not enabled | re-run with `MS_CALENDAR_WRITE=1` |
| `create/update/delete` returns **403 ErrorAccessDenied** | token was minted read-only (`Calendars.Read`) | re-mint with the ReadWrite scope (`node tools/ms-graph-login.mjs <CLIENT_ID>` defaults to it), then `MS_CALENDAR_WRITE=1 ONLY='calendar' ./setup-finn.sh` |

The server is at `/sandbox/mcp/` and creds at `/sandbox/.config/ms-calendar.env` — both live in the
sandbox workspace (out of the image/repo), so **re-apply after a full rebuild** (`onboard`).

### Symptom: agent says calendar is **blocked by network policy** (it *tried*) but `diagnostics` is perfect

This is the **egress trap** — the most painful one. The agent has the tool and calls it, but the
gateway-spawned MCP server can't reach Microsoft, so it replies *"unable to access your calendar …
network restrictions … login.microsoftonline.com and graph.microsoft.com blocked."* Why: the
**gateway runs in a proxy-only netns** (direct egress blocked; the proxy does TLS interception) *and*
**OpenClaw spawns the MCP child with a scrubbed env** — so the child has no `HTTPS_PROXY`/CA and its
`fetch()` tries (blocked) direct egress. `diagnostics` looks fine because it runs the server in
the open **main** netns (`docker exec`) — wrong namespace, so it misleads you.

**The current `mcp/ms-calendar-mcp.mjs` already fixes this**: on startup it detects the missing proxy,
reads it from its gateway ancestor's `/proc/<ppid>/environ`, and re-execs itself with `HTTPS_PROXY` +
`NODE_USE_ENV_PROXY=1` + `NODE_EXTRA_CA_CERTS` so Node routes through the proxy and trusts the MITM CA.
So the fix is just to **make sure the up-to-date server is deployed** — re-run `ONLY='calendar' ./setup-finn.sh`
(it re-copies the server, registers it, and restarts the gateway).

### Symptom: agent says "no access" and did **not** try (no calendar tool mentioned)

Different cause: a **stale cached MCP runtime**. Registering the server hot-reloads the config, but a
hot reload does **not** rebuild the gateway's cached per-workspace MCP runtime, so the agent keeps its
old tool catalog (no calendar tools). ⚠️ **OpenClaw 2026.5.x (the stock onboard) has no `openclaw mcp reload`** (only
`list/serve/set/show/unset`), and `nemoclaw recover` only hot-reloads here — so the *only* way to rebuild
the runtime is a **full gateway restart** (the supervisor relaunches a fresh gateway). Fix:

```bash
cid=$(docker ps --filter name=openshell-finn --format '{{.Names}}' | head -1)
# kill the gateway worker = the `openclaw` process whose parent is nemoclaw-start; the supervisor relaunches it.
docker exec -u 0 "$cid" sh -c 'for p in $(pgrep -x openclaw); do pp=$(awk "{print \$4}" /proc/$p/stat); tr "\0" " " </proc/$pp/cmdline | grep -q nemoclaw-start && kill -TERM $p; done'
# confirm a fresh "[gateway] http server listening" + "ready" in /tmp/gateway.log
```

`ONLY='calendar' ./setup-finn.sh` does exactly this restart automatically, so a normal re-run also fixes it.
(Do **not** match the worker by `pkill -f "gateway run"` — on some onboards its argv is just `openclaw`.)

### Other gotchas

- **`nemoclaw finn doctor`** can report the sandbox "Ready" while the gateway is still settling —
  trust a fresh `http server listening` / `[gateway] ready` line in `/tmp/gateway.log`, not `doctor`
  or a socket probe (see "Gateway health" above).
- **Binaries are at `/usr/local/bin`** on the stock v0.0.67 base (`openclaw`, `node`) — the
  `fixes/*.yaml` `binaries:` entries reflect that. (On the old community base they were `/usr/bin/*`.)
- **Shared Telegram credential**: if `nemoclaw status` warns that `finn` and another sandbox share one
  Telegram credential, only one bridge can poll. `nemoclaw <other> channels stop telegram`.
