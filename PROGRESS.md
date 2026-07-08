# PROGRESS.md — finn build log

A chronological log of what was built/changed on **finn** (the NVIDIA DevRel research
agent: OpenClaw sandbox on NemoClaw/OpenShell). **Newest first; absolute dates.** The
distilled gotchas live in [`docs/LEARNINGS.md`](./docs/LEARNINGS.md); the *why*/security model in
[`architecture/`](./architecture/_index.md) (split into an index + 6 parts); run steps in [`README.md`](./README.md). Append a
new dated entry at the top as work lands.

> [!note] Entries below cite `CLAUDE.md` — the maintainers' working notes, which are kept out
> of the published repo. Everything still current from them is distilled into
> [`docs/LEARNINGS.md`](./docs/LEARNINGS.md). Development ran branch → PR in a private working
> repository; this public repo is a curated snapshot, so the PR numbers cited below refer to
> that private history.

> **Current state** (2026-06-28): finn = a sandbox on **nemoclaw v0.0.68 / OpenClaw 2026.6.10**
> (model **`nvidia/nemotron-3-super-120b-a12b`** — a **base re-onboard on 2026-06-28 reverted it from
> ultra-550b** and wiped ALL runtime state; the full stack was re-applied live, see the top entry). Web
> **search** = brave (OOTB); **fetch** = **Firecrawl** (now a *baked plugin*
> — 2026.6.x un-bundled it); control channel = **Telegram**. Optional MCP add-ons: **calendar**
> (Outlook/live.com, `runmod-finn-live.sh`) + **Notion** (`runmod-notion-live.sh`), read-only by
> default. The **proactive layer** (conference radar + topic trends + weekly digest over the
> event-intelligence Notion) is **paused**: **BLOCKER 1** (cron can't drive tools) **collapses on
> 2026.6.x** (command jobs + the cron-preflight patch), and **BLOCKER 2** (weak executor that forced
> one-item-per-run) **may now ease** on Ultra-550B — *untested, re-evaluate before rebuilding the
> loops*. The repo is published at **github.com/vbhchua/finn-agent** (private, Apache-2.0). Rebuilding
> the 2026.6.10 base needs **`patches/nemoclaw-2026.6.x-chat-send-runid.patch`** (upstream NemoClaw
> ≤ v0.0.68 only covers OpenClaw ≤ 2026.6.8). The Notion workspace finn maintains is a **three-pillar
> DevRel hub** since 2026-07-06 (This Quarter · People CRM · Accounts) with strict column ownership —
> see that entry below before editing prompts or the bootstrap.

---

## 2026-07-08

- **Consolidated the four `runmod-*.sh` add-ons into a single, `.env`-driven `setup-finn.sh`.** One
  idempotent configurator now onboards a stock sandbox if missing, then applies every layer — Telegram,
  Brave search, Firecrawl fetch, the inference model (compatible-endpoint primary + optional OpenRouter
  fallback), the calendar + Notion MCP servers, and the radar crons — each running only if its keys are
  in `.env`; scope with `ONLY=`/`SKIP=`. The near-duplicated skeleton (container discovery, presets-dir
  resolution, proxy/CA derivation, `openclaw mcp set`, the TERM-worker gateway restart) is factored into
  shared helpers, so the one file is smaller than the sum of the runmods. Inference is generalized from
  the hardcoded `KIMI_*` knobs to `INFERENCE_MODEL_ID` / `INFERENCE_ENDPOINT_URL` (swap providers by
  editing `.env`, no code change). Removed `runmod-{finn,notion,conference-radar,models}-live.sh`;
  README/SETUP/`.env.sample`/CLAUDE(.local) updated. ⚠️ Syntax-checked only (`bash -n` + both embedded
  python heredocs parse) — NOT exercised end-to-end; must be validated against a live EC2 bring-up
  before it's trusted (no running sandbox in this session).

- **Fresh-host base-build is now a documented, idempotent one-liner (`tools/build-finn-base.sh`).**
  A from-scratch onboard on a new EC2 failed at `FROM nemoclaw-finn-base:2026.6.10` with *"pull access
  denied … repository does not exist"* — the base image is built locally and never pushed, so a host
  that lacks it tries (and fails) to pull it. The golden path assumed the base already existed (true on
  the dev Mac, not on a fresh host). Added `tools/build-finn-base.sh` (pins NemoClaw v0.0.68, applies the
  vendored patch, builds; skips if the tag is present, `FORCE=1` rebuilds), a step 0 in the README/SETUP
  golden paths, a "Fresh host / new EC2" section (build-first ordering, the arch caveat — don't ship an
  arm64 image to x86_64 — and registry/ECR reuse via `docker pull` + re-tag, since `nemoclaw onboard` has
  no `--build-arg`), and LEARNINGS §6. Idempotent skip-guard verified; the full clone+patch+build path is
  a faithful transcription of the documented commands (not run end-to-end in this session).

- **Reverted the host-gateway macOS launchd LaunchAgent (the 2026-07-07 `com.nemoclaw.openshell-gateway`
  work).** In practice it *double-managed* the host gateway: launchd (RunAtLoad + KeepAlive) fought
  `nemoclaw`'s own gateway supervision over `127.0.0.1:8080`, while a stray `brew services` gateway
  (`homebrew.mxcl.openshell`, :17670, from a 2026-06-24 experiment) added a third contender. Net effect
  was an *"Address already in use"* restart-storm — launchd looping on exit 1, `runtime.json` pointing
  at a pid that died seconds later, and the finn sandbox getting re-created un-onboarded during the
  churn (Telegram channel + pairing wiped along with the rest of the runtime layer). Host supervision is
  deferred to **systemd on the planned Linux EC2 host**, where the gateway is one service with no
  competing manager. **Kept** `radar/gw-cron.sh`'s token-based out-of-band gateway-PID fallback — it is
  needed under systemd too (the gateway is reparented, so the `nemoclaw-start`-child lookup wouldn't find
  it). Removed `tools/install-gateway-launchagent.sh` and its launchd docs; the model-provider work
  (Kimi K2.6 / OpenRouter, 2026-07-07) is untouched. Reboot-death remains an open item until the EC2
  systemd unit lands (LEARNINGS §9).

## 2026-07-07

- **Inference switched to Kimi K2.6 (Moonshot AI) via the gateway's `compatible-endpoint`
  provider; OpenRouter wired as an optional direct fallback route (`runmod-models-live.sh`).**
  The sandbox keeps calling the managed `inference.local` route — the HOST gateway now forwards
  it to `https://api.moonshot.ai/v1` (key gateway-side only; the sandbox config keeps the
  non-secret `apiKey: "unused"` placeholder, so NemoClaw's compatible-endpoint smoke check
  passes as-is). Root cause of the initial smoke failure: a **resumed** onboard skips the
  OpenClaw config step, leaving `agents.defaults.model.primary` pinned to the previous model
  (`inference/nvidia/nemotron-3-super-120b-a12b` vs expected `inference/kimi-k2.6`) — the new
  runmod rewrites the model block idempotently and TERM-restarts the gateway worker
  (LEARNINGS §6). Second path: `fixes/openrouter.yaml` opens `openrouter.ai` egress for
  OpenClaw's **built-in** openrouter provider (`openrouter/<author>/<slug>` refs +
  `OPENROUTER_API_KEY` in config env — no `models.providers` block needed); default fallback
  `openrouter/moonshotai/kimi-k2.6` = the same model over an independent route. Verified live:
  `kimi-k2.6` PONG through `inference.local` from the gateway netns (0.4 s, `reasoning_content`
  present — K2.6 runs as a thinking model), a no-tool agent PONG end-to-end, and
  `openrouter.ai/api/v1/models` 200 through the egress proxy **as node** — a curl probe 403s
  because policy `binaries` are enforced (LEARNINGS §4). `.env.sample` gains
  `MOONSHOT_API_KEY` (consumed at onboard by the gateway provider) + `OPENROUTER_API_KEY`
  (consumed by the runmod).

- **topic-trends sharded: all-topics-per-run → two-topics-per-run daily rotation.** A live
  sequential test of all three cron jobs at shared-endpoint evening peak (25 concurrent requests,
  ~3 gen tok/s — vs 9 / ~67 tok/s the same morning) showed the all-topics run cannot fit its 900s
  job budget under load (`cron: job execution timed out`, 0 of 15 snapshots written), and projected
  context/cost budgets (~173k of a 262K window, ~6M processed tokens per run) made it the first
  loop to hit every ceiling as the watchlist grows. The fix: `radar/prompts/topic-trends.md` now
  processes EXACTLY TWO topics per run — the two oldest by a new Topics.`Last snapshot` date
  (stamped by the run itself), so 15 watched topics rotate fully ≈ weekly at ~25k context /
  ~3 min per run. The schedule moves from Sun 18:00 (evening peak — the slow lane) to daily
  09:30 SGT, staggered behind conf-radar. The emerging-topic scan leaves the loop (it was the
  unbounded-growth source) and becomes a deep-refresh duty. Also: `notion-bootstrap.mjs` creates
  the new column, and the weekly-digest queries gain explicit limits (15/10) so its fan-in stays
  bounded as the events DB grows. Endpoint-independent: the shard is a prerequisite for any model
  choice, not an alternative to one (an unsharded run needs ~100+ tok/s sustained to fit 900s).

- **README/SETUP now lead with the golden path** — the stack finn actually runs: onboard the
  **OpenClaw 2026.6.10** image (`--from Dockerfile.finn-2026.6.10`), then all five steps standard
  (Firecrawl+Brave+Telegram, calendar, Notion, radar — write flags on, matching practice); the
  stock 2026.5.x onboard is demoted to a "minimal search-only variant". SETUP.md's stale "the live
  finn is 2026.5.27" callout fixed, and the one-time 2026.6.10 base build (vendored patch +
  `docker build`) surfaced from the Dockerfile header into its own SETUP.md subsection. README
  gains a **Credits** section acknowledging the NVIDIA **NemoClaw for OpenClaw blueprint**
  (build.nvidia.com) the agent derives from. Follow-up on the same PR: **the v0.0.68 pin is now
  enforced, not just documented** — nothing previously guaranteed the NemoClaw version (the CLI on
  PATH was unchecked; the base-build clone was unpinned; only the fail-closed patch guarded one
  file). Now: `setup-finn.sh` step 0 preflights `nemoclaw --version` (abort if < v0.0.68, warn if
  newer + hint to drop the vendored patch, `NEMOCLAW_VERSION_SKIP_CHECK=1` to bypass), and
  SETUP.md + the Dockerfile header pin the checkout with
  `git clone --branch v0.0.68 --depth 1 …/NemoClaw.git`.

- **Scope narrowed to pure-Singapore DevRel (Victor's call, same day):** SG-located events are the
  attendance/commit pipeline; regional (non-SG) events are an **intelligence feed only — speaker
  rosters + theme trends**, never travel. The venue convention carries the signal: regional Venue
  options contain `" · <Country>"`, SG options don't. Prompt deltas: **conf-radar** — on a regional
  event, only speakers/themes matter; **weekly-digest** — "Coming up" is SG-only, plus a new
  "🌏 Regional watch" section (≤3 lines, never action items). Notion side: the 🧭 This Quarter
  pipeline view is SG-filtered, a "🌏 Regional watch" view was added, and all 10 regional Proposed
  rows carry 🌏 speakers/trends-only next actions.

- **The event-intel Notion was restructured into a three-pillar DevRel workspace; finn's prompts gained
  matching write-guardrails.** The hub ("AI Events Singapore — BD Intelligence Hub") now leads with three
  human-facing pillars on top of the data layer finn maintains:
  1. **🧭 This Quarter — DevRel Focus** (new page): triage board for `Proposed` events, the upcoming
     pipeline with Victor's new `My plan` / `Next action` / `Action due` columns, a commitments view,
     and the trend history.
  2. **🧑‍🤝‍🧑 People — AI Ecosystem SG** (the Speakers DB, renamed + extended): CRM columns `Stage`,
     `Priority`, `Channel`, `Last touch`, `Next step`, and `NVIDIA Offering` (a 9-option multi-select
     aligned 1:1 with the offerings in `my_company_profile.yaml`); new **🔥 Outreach pipeline** board;
     the 🎯 BD Shortlists page is now a live board grouped by offering instead of static text.
  3. **🏢 Accounts — Singapore** (new DB, seeded with 18 organisations): the gov/stat-board/GLC/telco/
     research landscape, each mapped to NVIDIA technologies, with two-way relations `Key people` (→
     People) and `Seen at` (→ Events).
- **Ownership matrix (the load-bearing rule, now written into the hub AND the prompts):** finn's loops
  own event/speaker *facts* + the cadence columns (`Last checked` / `Next check due` / `Latest change`);
  **Victor owns the decision columns** (`My plan`, `Next action`, `Action due`, `Stage`, `Priority`,
  `NVIDIA Offering`, `Channel`, `Next step`, `Last touch`, and all of 🏢 Accounts). All three radar
  prompts updated: conf-radar writes ONLY its three cadence properties; topic-trends and the digest are
  explicitly read-only on Events; the digest now surfaces `My plan` in "Coming up" (and drops ⛔ Skip
  events).
- **Two-tier refresh model (documented):** the **periodic loops run on Nemotron super-120b** — literal,
  one-item-per-run prompts, cadence-column writes only; the **deep refresh runs on a frontier model**
  (Claude Opus-class) via the vault runbook `event-intelligence/refresh-bootstrap-prompt.md`, which owns
  event/speaker *content* reconciliation and now also People-dedup + Accounts hygiene. Neither tier ever
  writes Victor's columns.
- **Not yet in code:** `radar/notion-bootstrap.mjs` does not create the new Victor-owned columns or the
  Accounts DB (they were added via the Notion MCP host-side). If the workspace is ever rebuilt from
  scratch, extend the bootstrap first — flagged rather than shipping untested API code.

## 2026-06-28

- **OUTAGE + full recovery: a base re-onboard silently wiped finn's entire runtime stack; rebuilt it live
  from a new `.env`.** Symptom Victor saw: *"Telegram doesn't seem to be connected"* (and earlier, *"The
  agent run failed before producing a reply"*).
  - **Root cause.** finn's sandbox was **re-onboarded from base ~22:45 SGT** (new container UUID, new
    `openshell/sandbox-from` image tag). The sandbox data dir `/sandbox/.openclaw` is **ephemeral — no
    bind-mount** (only the supervisor binary is mounted), so the re-onboard wiped **everything added at
    runtime**: the Telegram channel, the **calendar + Notion MCP servers**, the **radar cron loops**, the
    **Brave search key**, and it **reverted the model ultra-550b → super-120b**. *Only the host-side egress
    **policies** survived* (they live in the blueprint, not the image), which is why `nemoclaw finn list`
    still showed `telegram, ms-calendar, notion, …` while the in-sandbox config had none of it.
  - **Recovery sequence (reproducible).** All driven from a new gitignored **`.env`** (8 keys; added
    **`.env.sample`** as the template; locked `.env` to `600`):
    1. `nemoclaw finn channels add telegram` (token from `.env` piped to its stdin prompt) → bakes Telegram
       into the image + rebuilds.
    2. `nemoclaw finn rebuild` → **clean, supervisor-managed boot** (see the `docker restart` trap below).
    3. `MS_CALENDAR_WRITE=1 ./runmod-finn-live.sh` · `NOTION_WRITE=1 ./runmod-notion-live.sh` ·
       `./setup-finn.sh` (Firecrawl) · `./runmod-conference-radar-live.sh` (3 cron jobs re-registered) —
       all idempotent, all re-apply cleanly now that the supervisor loop is back.
    4. **Brave** (the gap setup-finn.sh missed): `config set …brave…webSearch.apiKey` + `policy-add brave`.
  - **End state: all green** — healthy, Telegram bidirectional (@sgfinn_bot, verified round-trip),
    inference OK, `web_search` verified live (brave key + egress), calendar/Notion MCP read/write, 3 radar
    cron jobs → Telegram, and `web_fetch` (firecrawl) **confirmed live over Telegram 2026-06-29**. The
    intermittent **NVIDIA inference idle-timeout** (`LLM idle timeout` / `ResourceExhausted` in the logs)
    is environmental — it surfaces as tool "fetch failed" / "couldn't generate a response"; re-test before
    chasing it as a wiring bug. `#process`

- **TRAP — never `docker restart` an OpenShell sandbox.** The container ENTRYPOINT is the **supervisor**
  (`openshell-sandbox`), driven by the host orchestration over the SSH relay — NOT the gateway. On a raw
  `docker restart` the supervisor comes up and just runs **`sleep infinity`**: the `nemoclaw-start` monitor
  loop never starts, so the gateway never launches AND (worse) nothing will respawn it if later killed. This
  is what turned a config tweak into a dead finn. **Correct restart paths:** `nemoclaw <name> rebuild`
  (clean, host-managed boot, correct markers) or the runmods' `kill -TERM <gateway worker>` **only when the
  `nemoclaw-start` loop is present** (verify: `ps -eo args | grep -c '[n]emoclaw-start'` ≥ 1; a healthy boot
  shows ~6). `nemoclaw recover` relaunches the gateway *out-of-band* but leaves a **stale
  `/tmp/nemoclaw-gateway.pid`** and then **loops forever** waiting for a health it can't see. `#process`

- **TRAP — stale pid marker → false `unhealthy` (and the health probe netns false-negative, again).** The
  docker healthcheck `curl`s `127.0.0.1:18789/health` from the **main netns**, but the gateway listens in its
  **own netns** → rc=7 → it falls back to checking `/tmp/nemoclaw-gateway.pid`. After an out-of-band relaunch
  that file holds the **dead** pid → fallback fails → `unhealthy`, even though Telegram/inference work fine.
  Fix: `pid=$(docker exec <c> pgrep -x openclaw|head -1); echo "$pid" > /tmp/nemoclaw-gateway.pid` (or just
  rebuild). Corollary: **`openclaw config get` redacts secrets** (always reads back `__OPENCLAW_REDACTED__`),
  so it's useless for verifying a key was set — check the raw `openclaw.json` or do a live call. `#process`

- **Patched `setup-finn.sh` to own the Brave key + egress (new step 2b).** It used to assume *"BRAVE_API_KEY
  auto-injected by onboard"* — true only for a fresh onboard with the key in env. A bare re-onboard leaves
  brave with a **placeholder apiKey** and the **`brave` egress preset inactive** → `web_search` fails *"fetch
  failed"* (today's exact failure). Step 2b now `policy-add brave --yes` + `config set
  plugins.entries.brave.config.webSearch.apiKey` when `BRAVE_API_KEY` is set — idempotent, mirrors the
  Firecrawl key block; `BRAVE_API_KEY` documented in the usage header + `.env.sample`. `#process`

## 2026-06-27

- **OpenClaw 2026.6.10 upgrade SHIPPED — finn re-onboarded live; repo published.** Completes the
  2026-06-26 "built + proven" work.
  - **finn is live on OpenClaw 2026.6.10 / nemoclaw v0.0.68** (`nemoclaw onboard --from
    ./Dockerfile.finn-2026.6.10 --name finn`): firecrawl + brave plugins enabled, `web_fetch=firecrawl`,
    proxy `gateway-only`. **Model upgraded to `nvidia/nemotron-3-ultra-550b-a55b`** (was super-120b-a12b).
  - **`onboard --from` messaging-ARG gotcha — fixed (NemoClaw #5729 class).** A thin `--from` Dockerfile
    must declare **`ARG NEMOCLAW_MESSAGING_PLAN_B64`** *and* run the messaging applier, else `onboard`
    and `channels add` both die with *"Dockerfile is missing ARG NEMOCLAW_MESSAGING_PLAN_B64; cannot
    apply messaging plan"* (`dockerfile-patch.js` only throws when a plan is present). Added the ARG +
    ENV + the 3-phase applier (`--agent openclaw`, runtime-setup/agent-install/post-agent-install — the
    base already ships `/src/lib/messaging`) to `Dockerfile.finn-2026.6.10`. The plan/token is injected
    at onboard, never baked.
  - **NemoClaw 2026.6.9+ chat-send patch vendored for reproducibility.** Upstream NemoClaw (≤ v0.0.68,
    incl. `main`) only covers OpenClaw ≤ 2026.6.8; 2026.6.9 changed the `runQueuedFollowup` run-id
    callsite (`sessionId: effectiveQueued.admissionSessionId ?? run.sessionId`). The 1-line regex
    tolerance now lives at **`patches/nemoclaw-2026.6.x-chat-send-runid.patch`** (validated to apply to a
    pristine v0.0.68; `git apply` it before building the base), referenced by the Dockerfile prereq. The
    fragile uncommitted edit in the NemoClaw checkout was removed.
  - **BLOCKER 2 may have dissolved.** The one-item-per-run radar decomposition was forced by the weak
    Super-120B; on **Ultra-550B** the multi-item conf-radar / 15-topic loops may now complete in one run.
    **Untested** — re-evaluate (and possibly simplify away the dispatcher) before rebuilding the loops.
  - **Repo published: `github.com/vbhchua/finn-agent` (private, Apache-2.0).** Hero-banner README (ASCII
    `FINN` wordmark + badges + a "What it does" table) trimmed to **Quick Setup**; full setup, MCP
    add-on internals, Exa variant, manual steps, and troubleshooting moved to a **`SETUP.md`** companion.
    `.gitignore` excludes secrets / `.DS_Store` / `.claude/` / `digicon.html`; secret-scanned before push.
  - **Workflow now in force (Victor's):** every repo change goes on a **branch → PR**; Victor squash/
    merges (he's the gatekeeper). **Conventional Commits for commits AND PR titles** (the PR title becomes
    the merge/squash subject). `#process`

## 2026-06-26

- **OpenClaw 2026.6.10 upgrade — BUILT + proven (non-destructive); onboard pending (Victor runs it).** This
  reverses the 2026-06-24 "stay pinned to 2026.5.27" stance now that the right path is understood. The naive
  in-place `npm install -g openclaw@latest` (reverted 2026-06-24) was always wrong — NemoClaw pins + patches
  OpenClaw. The correct path = **bump NemoClaw, then build**:
  - **Bumped the NemoClaw checkout v0.0.67 → v0.0.68** (npm-linked at `round-02/NemoClaw`; detached at tag
    `v0.0.68` = `420ec884e`; `main` left at `0af4850dc` so `git checkout main` reverts). Rebuilt `dist/`
    (`npm install` → `prepare`/`build:cli`) so the CLI runs real v0.0.68. v0.0.68 adds OpenClaw **2026.6.x**
    chat-send patch support (its shim header now reads "2026.5.x and 2026.6.x").
  - **Found + fixed the real blocker: latest NemoClaw supports OpenClaw ≤ 2026.6.8.** Even `main` (byte-identical
    patch) fails on 2026.6.9/.10 — in 2026.6.9 OpenClaw restructured the `runQueuedFollowup` run-id callsite
    (`sessionId: run.sessionId` → `sessionId: effectiveQueued.admissionSessionId ?? run.sessionId`), so the
    chat-send run-id patch **fails closed** (refuses to corrupt the runtime — the safe behavior). **Fix = a 1-line
    regex tolerance** in `NemoClaw/scripts/patch-openclaw-chat-send.js` (line 204, the `admitReplyTurn` branch),
    mirroring the patch's existing optional-`routeThreadId` group; inserted run-id code unchanged; still
    self-verifies + fails closed. Standalone-verified on 2026.6.8/.9/.10. **This is a local NemoClaw fork delta**
    to carry until upstream ships 2026.6.9+ support (could be upstreamed — it's the NemoClaw repo).
  - **Built the full production image** with `--build-arg OPENCLAW_VERSION=2026.6.10 --build-arg
    NEMOCLAW_WEB_SEARCH_ENABLED=1` → `nemoclaw-finn-base:2026.6.10` (OpenClaw 2026.6.10 confirmed inside). All
    patch gates pass: 5 inline patches incl. **Patch 6 = cron-preflight** (relevant to the cron blocker),
    tool-catalog now **native** (skip — the compact catalog got upstreamed), chat-send (fixed), brave
    web-search plugin@2026.6.10 installed + enabled.
  - ⚠️ **firecrawl/exa are UN-BUNDLED in OpenClaw 2026.6.x** (exactly the "un-bundles firecrawl/exa" the
    2026-06-24 note warned of) — they moved from bundled stock extensions to install-from-catalog plugins. Both
    `@openclaw/{firecrawl,exa}-plugin@2026.6.10` exist on npm; `npm:` install spec works on 2026.6.x (the old
    `clawhub:` requirement was an old-OpenClaw artifact). A *runtime* `openclaw plugins install` needs npm-registry
    egress (deny-by-default blocks it), so the robust path **bakes firecrawl at build** — new
    **`Dockerfile.finn-2026.6.10`** (FROM the 2026.6.10 base + proxy-toggle + `npm:@openclaw/firecrawl-plugin@2026.6.10
    --pin`, search stays brave, key NOT baked). Verified built: firecrawl enabled, fetch=firecrawl, proxy
    restored + gateway-only, apiKey absent. **`setup-finn.sh` updated** to be version-aware (≤2026.5.x enable bundled;
    ≥2026.6.0 install version-matched plugin, with a bake-at-build fallback).
  - **Onboard (Victor):** `nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn` (there's no
    `--openclaw-version` flag), then `./setup-finn.sh` to inject `FIRECRAWL_API_KEY` + policy + /etc/hosts, then
    re-apply the calendar/Notion/radar runmods. Re-onboard wipes the live finn + all add-ons (needs `NOTION_TOKEN`,
    `FIRECRAWL_API_KEY`, the MS-Graph token).
  - **Cron blocker status:** the upgrade gives OpenClaw **command jobs** (`--command`/`--command-argv`) + the
    cron-preflight patch → **BLOCKER 1 (cron can't drive tools) collapses**. **BLOCKER 2 (weak Nemotron → only
    simple one-item runs) is unchanged** — the host-side scheduling + one-item-per-run decomposition still apply.
  - New/changed files: `Dockerfile.finn-2026.6.10` (new), `setup-finn.sh` (firecrawl install-based), local
    `NemoClaw/scripts/patch-openclaw-chat-send.js` (+1-line tolerance), image `nemoclaw-finn-base:2026.6.10`.
  `#process`
- **Documented the proactive-loop *scheduling architecture* in `ARCHITECTURE.md` §5** (new section;
  Net posture bumped to §6). Names the pattern the radar already runs on — **state-indirection +
  producer→consumer chaining**: the changing work-list lives in a **shared store**, never in a cron
  prompt; each scheduled run is a *fixed* prompt that reads current state at fire time; **earlier
  loops write state later loops read.** §5 ties it to finn concretely: the **dynamic list** = the
  `📅 AI Events` + `finn · Topics` DBs; the **"what's due" selector** = the `Next check due` Notion
  date-filter (what makes it change day to day); **producers** = conf-radar + topic-trends; the
  **consumer** = the Monday digest (it already reads what they wrote). Records *why* the obvious
  OpenClaw-cron approach can't work (fixed prompt / no native iteration / no job-chaining [RFC
  #28584] / + finn's two blockers) and *why Notion* over a flat file (allowed egress host already,
  durable + human-curatable, survives rebuild, doubles as the digest's data source).
- **Designed the `topic-trends` unblock (DESIGN ONLY — no scripts written, Victor's call).** Apply
  the **same one-item-per-run decomposition** that fixed conf-radar (proven 2026-06-25) to the still-
  broken 15-topic loop, via a **two-tier store** (durable state in Notion + a transient per-cycle
  **work-queue file**): a cheap host-side **dispatcher** (`radar/dispatch.sh`, *proposed*, no model)
  queries what's due and **stages one prompt `.msg` per due topic** under `/sandbox/.cache/radar/
  queue/`; the host scheduler then fires `run-job.sh` **once per queued item** (rigid single-item
  checklist → 1 snapshot write → mark `Last snapshot`/`Next check due`). Moves the *iteration* off
  the weak model onto deterministic host code; each Nemotron run stays atomic/single-item. Idempotent
  (due-filter), at-least-once (failed item stays due → re-enqueued next cycle), ordering by schedule
  offsets (no native chaining). Generalizes to conf-radar (dispatcher picks the due event instead of
  asking the model). Full writeup: `ARCHITECTURE.md` §5.4–5.5. **Not yet built/verified** — deploy +
  test against the live sandbox in a later session (the netns/host-schedule wiring still needs the
  paused launchd-vs-manual decision from 2026-06-25 TODO (a)).
- **Security framing (ARCHITECTURE.md §5.6):** the pattern is pure scheduling/decomposition — **no
  trust-boundary change.** The proposed dispatcher is the same host-side / no-new-capability shape as
  `notion-bootstrap.mjs`; per-item runs reuse §4 items 1 (web read) + 7 (Notion write) verbatim — no
  new egress host, no new inbound surface (the queue is host-internal scratch), output still human-
  reviewed in the digest, discoveries still land as `Proposed`. `#process`
- **Split `ARCHITECTURE.md` (was ~490 lines) into the `architecture/` folder** for readability: an
  index (`architecture/_index.md`) + **6 numbered parts** (`01-what-finn-is` · `02-trust-and-egress`
  [§2+§3] · `03-security-analysis` [§4 core: loopback, deltas 1–5, preserved] · `04-add-on-security`
  [§4 items 6–8: calendar/Notion/radar] · `05-scheduling-architecture` [§5] · `06-net-posture` [§6]).
  Each part has prev/next/index nav; cross-refs are Obsidian wikilinks (pipes avoided inside tables);
  **section numbers §1–§6 + §4 items 1–8 preserved** so old "§4 item 6" citations still resolve.
  The old monolithic `ARCHITECTURE.md` was first kept as a redirect stub, then **removed** (per
  Victor) — the folder is the sole home; no clickable links to it remained. Live pointers updated:
  README (calendar note → `architecture/04-add-on-security.md`), CLAUDE Key-files row, PROGRESS header. Also folded in a §5.1 tip: an OpenClaw/NemoClaw upgrade collapses BLOCKER 1 (cron
  command jobs) but not BLOCKER 2 (the weak model) — the dispatcher design survives. `#process`

## 2026-06-25

- **Conference Radar + Topic-Trend loops (Features 4 & 5) — PARTIAL / PAUSED.** Infra + data layer all
  built & proven; the OpenClaw-cron deployment hit a hard platform wall (below). Single-event radar
  PROVEN working via the agent path. **Paused 2026-06-25 pending a scheduling-deployment decision.**
  - ✅ **Notion bootstrap (works):** extends existing `📅 AI Events — Singapore` in place
    (+ `Last checked`/`Next check due`/`Latest change`); created `finn · Topics` + `finn · Trend
    snapshots` under the BD Intelligence Hub; seeded **18 topics** (aligned to existing `Themes`),
    **15 real-data trend-baseline rows** (from actual Theme tallies across 9 upcoming events), and
    **12 curated APAC sovereign-AI/govt events as `Proposed`**; primed 9 upcoming events. Run via
    `radar/notion-bootstrap.mjs` (host-side — the MCP has no `create_database`; keeps DB creation off
    the agent surface). Idempotent.
  - ⛔ **BLOCKER 1 — OpenClaw 2026.5.27 cron cannot drive tools.** Verified exhaustively (by checking
    real Notion writes, NOT the misleading `delivered:true`): scheduled `--message`/agentTurn runs
    **context-stripped** → Nemotron never calls tools, just echoes the prompt template; **command-jobs
    don't exist** on this pinned version (`--command-argv` rejected); `--system-event` only
    **async-enqueues**; flipping `skipBootstrap` made no difference. The ONLY path that injects the
    bootstrap/TOOLS.md tool-priming is **`openclaw agent --agent main`** (proven: real
    `notion__query_database` calls, real data). → Conclusion: scheduling must live on the **host** and
    invoke `gw-cron.sh agent --agent main` (the registered openclaw cron jobs were **removed** to avoid
    Telegram spam).
  - ⛔ **BLOCKER 2 — Nemotron does SIMPLE scheduled tasks, not COMPLEX agentic loops.** Even via the
    working agent path: the **digest** (simple read+compose) ✅; the original **9-event conf-radar loop**
    ❌ (10 read/search calls but **zero `update_page`**, garbled output). Fix per Victor's call:
    **rewrite conf-radar to ONE event/run** (rigid checklist: 1 query → 1 search → 1 fetch → 1
    `update_page` → 1-line message). → **PROVEN WORKING:** wrote `AI for Education Conference 2026`
    `Last checked=2026-06-25` / `Next check due=2026-07-09` (today+14, correct cadence) + clean
    `🟢 Radar …` one-liner. **`topic-trends` still needs the same 1-at-a-time simplification** (its
    15-topic loop will fail like the old radar did).
  - **Fixes applied live on finn (persist until rebuild):** model **`maxTokens` 4096 → 16384** (KEEP —
    Nemotron was hitting `stopReason:length` mid-reasoning before any tool call); **tool names
    namespaced** in prompts (`notion__query_database` etc.); Notion **select can't contain commas**
    (Venue sanitized); runmod **msg-filename bug** (`fill_stage` basename vs `add_job` jobname); a
    `skipBootstrap` flip (reverted — didn't help).
  - **Open / TODO (next session):** (a) **DECIDE + wire the host schedule** (launchd vs manual — Victor
    paused here); (b) simplify `topic-trends.md` to 1-topic-batch/run; (c) widen the digest's
    `next_month` query (currently empty — nearest event is Aug); (d) **rework `runmod-conference-radar-
    live.sh`** — its bootstrap/helpers/admin-grant/maxTokens steps are good, but its **openclaw-cron
    registration is dead** and must be replaced with the host-schedule install; (e) **correct CLAUDE.md**
    — the "Conference Radar" section describes the openclaw-cron approach as if it drives tools (it
    doesn't); the real mechanism is host-scheduled `openclaw agent --agent main`.
- **Cron-registration mechanics (still valid + reusable, even though cron can't drive tools):**
  `openclaw cron` is a live WS client to the gateway in its **own netns** → unreachable from
  `docker exec` (`nemoclaw exec` hangs); must run via **`nsenter`** into the gateway netns
  (`radar/gw-cron.sh` — also how we invoke `openclaw agent --agent main`). `cron add` needs
  **`operator.admin`**, but a headless onboard leaves no admin device to approve the upgrade → granted
  in the on-disk device table + restart (`radar/grant-cron-admin.py`). `cron list --json` =
  `{"jobs":[{id,name,…}]}`. Telegram chat id = **384368246** (Victor; from gateway log + confirmed by
  a `delivered:true` to it). New files: `runmod-conference-radar-live.sh`, `radar/{notion-bootstrap.mjs,
  gw-cron.sh,grant-cron-admin.py,run-job.sh,seed-topics.json,seed-conferences-apac.json,prompts/*.md}`.
- **Notion connector shipped (2nd MCP add-on).** ✅ **CONFIRMED end-to-end over Telegram 2026-06-25**
  (read + write): finn authenticated as integration "Openclaw Notion" in workspace "Victor Chua's Notion"
  and **created a real page** via `create_page` (write mode, `NOTION_WRITE=1`). A thin, zero-dep stdio MCP server
  (`mcp/notion-mcp.mjs`) mirroring the calendar add-on (EGRESS-TRAP re-exec, 0600 creds file).
  **Read + write, writes gated behind `NOTION_WRITE=1`** — 10 tools (`search`, `get_page`,
  `get_page_content`, `get_database`, `query_database`, `whoami`, `diagnostics` + `create_page`,
  `update_page`, `append_blocks`). Uses Notion's **local-server model + a static internal-integration
  token** (`NOTION_TOKEN`, `api.notion.com`) — the *hosted* `mcp.notion.com` MCP is OAuth/browser-only
  and can't drive a headless sandbox. New files: `mcp/notion-mcp.mjs`, `fixes/notion.yaml`
  (`api.notion.com` GET/POST/PATCH), `runmod-notion-live.sh`. Documented in CLAUDE.md + README +
  ARCHITECTURE §4 item 7. **Prereq (one-time):** create an integration at notion.so/profile/integrations,
  share pages/databases with it, then `export NOTION_TOKEN=…; NOTION_WRITE=1 ./runmod-notion-live.sh`.
- **Restart-finder bug fixed (both runmod scripts).** `pkill -f "gateway run"` matched nothing on a
  fresh onboard (the gateway worker's argv is rewritten to just `openclaw`), silently falling back to
  a useless `recover` so the MCP runtime never rebuilt. Now both scripts kill the `openclaw` process
  whose **parent is `nemoclaw-start`**. (Surfaced during the Notion build.)
- **Docs:** added `ARCHITECTURE.md` §4 item 7 (Notion trust boundaries) + this `PROGRESS.md`; swept
  stale `openclaw mcp probe`/`mcp reload` references out of README + CLAUDE.md current guidance
  (those subcommands don't exist on OpenClaw 2026.5.27 — use `mcp list` + a full gateway restart).

## 2026-06-24

- **Reviewed nemoclaw v0.0.55 → v0.0.67 and rebuilt the setup to the minimal shape.** The platform
  absorbed most of the old workarounds: the stock base now ships `nemoclaw-start` (so a plain
  `nemoclaw onboard` authenticates — **no `finn-base:local` build, no custom Dockerfile**); web search
  works OOTB (brave, key auto-injected); `proxy.loopbackMode=gateway-only`, `gateway.mode=local`,
  `tools.toolSearch=false` (Nemotron manifest), `tools.codeMode` off are all **defaults** now;
  firecrawl/exa ship as **bundled** stock extensions. Sandbox renamed **`finn-box` → `finn`**. New
  minimal **`setup-finn.sh`** (stock onboard + Telegram + bundled-Firecrawl fetch) + renamed
  **`runmod-finn-live.sh`**; old custom-image stack retired to **`deprecated/`**.
- **Calendar "no access to my calendar" bug fixed.** Root cause: `runmod`'s `openclaw mcp reload`
  step silently failed — **OpenClaw 2026.5.27 has no `mcp reload`/`probe` subcommand**, so the stale
  cached MCP runtime was never rebuilt and the Telegram agent kept an old (calendar-less) tool catalog.
  Fix = a **full gateway restart** (supervisor relaunch rebuilds the MCP runtime); `runmod-finn-live.sh`
  updated. Auth/egress/server were all fine the whole time.
- **OpenClaw 2026.6.10 upgrade attempted, then reverted — stay pinned to 2026.5.27.** ⛔ In-place
  upgrade broke nemoclaw v0.0.67's version-specific bundled patches: `speech-core/runtime-api.js`
  surface errors on agent turns + `ERR_MODULE_NOT_FOUND` in the reload handlers, and it **un-bundles
  firecrawl/exa**. NemoClaw pins OpenClaw deliberately; don't bump it in-sandbox. (Memory:
  `openclaw-version-pinned`.)
- **`brave` provider-profile re-import collision fixed.** Re-running onboard hit
  `custom provider profile 'brave' already exists → provider profile import failed` (OpenShell's
  `provider profile import` has no `--force`). `setup-finn.sh` now clears a stale `brave` profile
  before onboard.

## 2026-06-23

- **Calendar add-on shipped read+write, confirmed working end-to-end over Telegram.** A delegated
  Microsoft Graph calendar for a personal **live.com** account via a zero-dep stdio **MCP server** —
  read-only by default, extended to create/update/delete behind `MS_CALENDAR_WRITE=1` + a
  `Calendars.ReadWrite` device-code refresh token. The win required **THE EGRESS TRAP** fix: OpenClaw
  spawns MCP children with a scrubbed env in the gateway's proxy-only netns, so the server
  **self-bootstraps** the proxy + MITM CA by re-execing with env read from its gateway parent's
  `/proc/<ppid>/environ`. Files: `mcp/ms-calendar-mcp.mjs`, `tools/ms-graph-login.mjs`,
  `fixes/ms-calendar.yaml`.

## 2026-06-22

- **finn-box fully working** (gateway + NIM inference + Telegram + Firecrawl web search), the hard
  v0.0.55 way. Added an **Exa hybrid** search variant (Exa for `web_search`, Firecrawl for
  `web_fetch`). Hard-won fixes: the Firecrawl SSRF `dns.lookup` precheck needs an `/etc/hosts` pin
  for `api.firecrawl.dev`; `proxy.loopbackMode=gateway-only` is required (stock `proxy` floods the
  logs with `127.0.0.1:18789` SSRF denials). Wrote `ARCHITECTURE.md` (security posture vs stock).

## 2026-06-21

- **Initial finn-box build** on nemoclaw v0.0.55. Established the **DEAD END**: the community base
  can't run an authenticating gateway (no `nemoclaw-start`). Shipped the durable path — build the full
  production image once (`finn-base:local`) and layer a Firecrawl image on top as `USER sandbox`,
  inheriting the `nemoclaw-start` ENTRYPOINT. (All of this is now obsolete on v0.0.67 — see 2026-06-24
  — but it's the depth-of-stack debugging story.)
