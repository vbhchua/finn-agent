# finn — Field Notes

Hard-won learnings from building **finn** on **NVIDIA NemoClaw / OpenShell** — a sandboxed,
deny-by-default agent runtime. Each entry is *symptom → root cause → fix*, distilled from the
build log ([PROGRESS.md](../PROGRESS.md)); the security model and trust boundaries live in
[`architecture/`](../architecture/_index.md).

The theme across all of them: **in a sandboxed agent runtime, the failure you see is rarely the
layer that's broken.** Network namespaces make healthy services look dead, env scrubbing makes
working credentials vanish, and cached runtimes make registered tools invisible — so the
debugging discipline is to find the *authoritative* signal (usually a log, never a probe) before
touching anything.

---

## 1. The egress trap: an MCP child does not inherit the gateway's network

**Symptom.** A custom MCP server (calendar, Notion) works perfectly when tested by hand, but the
agent insists it has *"no access — blocked by the network policy."*

**Root cause — three stacked facts, each individually verified:**

1. The OpenClaw gateway runs in its **own network namespace** where direct egress is blocked;
   everything must go through the egress proxy (which also does **TLS interception** with its
   own CA).
2. When the gateway spawns an MCP server subprocess, it **scrubs the environment** — the child
   gets none of `HTTPS_PROXY` / `NODE_EXTRA_CA_CERTS` / `NODE_OPTIONS`. The `env` block in the
   `mcp.servers` config **does not reach the child** either.
3. A hand test via `docker exec` runs in the **main** netns, where direct egress is open — so
   every out-of-band probe (`diagnostics`, `mcp probe`) succeeds and **actively misleads you**.

So the gateway-spawned child sits in a proxy-only netns with a bare env, tries a direct
`fetch()`, and is blocked — while every test you run says it's fine.

**Fix: the server self-bootstraps by re-exec.** On startup, if it has no `HTTPS_PROXY`, it walks
its process ancestry (`/proc/<ppid>/environ` — the gateway parent *has* the proxy env) and
re-execs itself with `HTTPS_PROXY` + `NODE_USE_ENV_PROXY=1` +
`NODE_EXTRA_CA_CERTS=<the proxy's MITM CA>`. Run out-of-band (no proxied ancestor), it skips the
re-exec and fetches directly — auto-adapting to both contexts. See `mcp/ms-calendar-mcp.mjs`.

**Corollary:** an out-of-process MCP server is *not* automatically simpler than an in-process
plugin — a plugin shares the gateway's proxy dispatcher and CA for free; an MCP child must
bootstrap its own egress.

## 2. MCP registration and the cached runtime

- **The on-disk config key is `mcp.servers`, not `mcpServers`.** The bundled code references
  `mcpServers` 171× (it's the *import/discovery* name), but a hand-patch of a top-level
  `mcpServers` key is silently ignored. Register via the CLI (`openclaw mcp set <name> '{…}'`),
  which writes the right key.
- **Registering a server hot-reloads the config but does NOT rebuild the cached MCP runtime** —
  the agent keeps materializing tools from the *old* catalog, so it truthfully reports "no such
  tool" while `mcp list` shows the server. The fix on this build is a **full gateway restart**
  (there is no `mcp reload` subcommand on OpenClaw 2026.5.27).
- **Restart the gateway by name + parent, not by argv pattern.** `pkill -f "gateway run"`
  silently fails on onboards where the worker's argv is rewritten to just `openclaw`. Match the
  `openclaw` process whose **parent is `nemoclaw-start`** and `kill -TERM` it — the supervisor
  relaunches a fresh gateway (which rebuilds the MCP runtime from scratch).

## 3. Observability: the log is authoritative — sockets lie

The gateway's own netns makes every socket-level health check false-negative from a
`docker exec` (default netns): `ss -ltn`, `netstat`, even `/proc/net/tcp` all show the gateway
port unbound while it is perfectly healthy.

- The only reliable "gateway up" signal is the **gateway log**: a fresh
  `[gateway] http server listening` + `ready`. A log that simply *stops* is usually idle, not
  hung (slow model calls can take 2+ minutes).
- **Never auto-kill the gateway on a socket check** — you'd kill a healthy gateway in a loop.
- The Docker healthcheck curls the health endpoint from the main netns → always fails → falls
  back to a pid file. After an out-of-band relaunch that file holds a **dead pid**, so the
  container reports `unhealthy` while Telegram and inference work fine. Refresh the pid file or
  do a clean `rebuild`.
- `openclaw config get` **redacts secrets** (`__OPENCLAW_REDACTED__`) — to verify a key actually
  landed, read the raw `openclaw.json` or make a live call.

## 4. Deny-by-default egress in practice

- **`NET:OPEN DENIED <site>` during research is expected, not a failure.** The agent's direct
  fetch to an arbitrary site is blocked by design, then the fetch provider (Firecrawl) scrapes
  it **server-side** through its single allow-listed endpoint. Ignore the auto-drafted
  per-site policy proposals — allowlisting individual sites would defeat the single-endpoint
  design.
- **The Firecrawl plugin's SSRF precheck needs `/etc/hosts` help.** Before each call it does a
  `dns.lookup` of its own endpoint to prove it isn't private — but the sandbox's local resolver
  can't resolve *any* external host (all real egress resolves via the proxy). Pin the endpoint
  in `/etc/hosts` with **any public IP**: the precheck passes, and the actual request still goes
  through the proxy, so the pinned IP never needs to be current.
- **Policy `binaries` are enforced by the egress proxy — a `curl` probe 403s even when the
  policy is live.** A preset that lists `binaries: [openclaw, node]` opens the endpoint only for
  those executables; probing it with curl from the gateway netns returns *"CONNECT tunnel
  failed, response 403"* and looks like a broken policy. Probe with `/usr/local/bin/node`
  (`NODE_USE_ENV_PROXY=1` + the proxy env + MITM CA) — the same binary the real traffic uses.
- **`proxy.loopbackMode=gateway-only` is load-bearing, not a tweak.** With the stock `proxy`
  mode on this topology, the embedded agent's own loopback RPC to the gateway
  (127.0.0.1:18789) is routed into the OPA egress layer, which blocks
  loopback/link-local **unconditionally** — you cannot allowlist around SSRF hardening — and
  produces a ~1/sec denial flood. `gateway-only` takes the loopback RPC off the intercepted
  path; external egress is policed identically either way.

## 5. Sandbox lifecycle: what survives what

**The mental model that explains every trap here:** the sandbox data dir (`/sandbox/.openclaw`)
is **ephemeral — there is no bind-mount.** Everything added at runtime (channels, MCP servers,
cron jobs, API keys) lives only in the container's writable layer. A rebuild or re-onboard wipes
all of it; only host-side **egress policies** survive (they live in the NemoClaw blueprint, not
the image). Anything baked into the image (e.g. the Telegram token via `channels add`) survives
a rebuild.

- ⛔ **Never `docker restart` an OpenShell sandbox.** The entrypoint is the *supervisor*, driven
  by host orchestration — restarted raw, it just runs `sleep infinity`: the gateway never
  launches, and nothing will ever respawn it. Check for the supervisor loop with
  `ps -eo args | grep -c "[n]emoclaw-start"` (≥1 = alive).
- **The restart ladder:** (1) config change → `kill -TERM` the gateway worker (see §2), the
  supervisor respawns it; (2) wedged state → `nemoclaw <name> rebuild` for a clean
  supervisor-managed boot; (3) `recover` is a last resort — it relaunches out-of-band, leaves a
  stale pid marker (§3), and does not restore the supervisor loop.
- ⚠️ **On a custom-image onboard, read `rebuild`'s Target line before confirming.** A plain
  `nemoclaw rebuild` targets the *stock* base — on this sandbox that is a silent OpenClaw
  **downgrade** (2026.6.10 → 2026.5.27) that would drop the vendored patches. If the Target
  doesn't match the running version, abort and rebuild via the custom Dockerfile path instead.
- **After `recover`, tooling that finds the gateway by its `nemoclaw-start` parent breaks** —
  the worker is reparented to pid 1. `radar/gw-cron.sh` now falls back to the token-bearing
  out-of-band worker; also refresh `/tmp/nemoclaw-gateway.pid` with the live worker pid or the
  container's healthcheck keeps reporting unhealthy (§3).
- **Recovery after a wipe is a runbook, not archaeology:** secrets live in a gitignored `.env`,
  and the setup is idempotent — re-run `./setup-finn.sh` (it re-onboards if needed, then re-applies
  Telegram + every layer), then verify (MCP list, cron list, one live search). Design for the wipe on day one.

## 6. Re-onboard traps

- **On a fresh host, build the base image BEFORE `onboard` — a Docker *pull* error for a
  local-only tag is the tell.** `Dockerfile.finn-2026.6.10` starts `FROM
  nemoclaw-finn-base:2026.6.10`, which is built locally and never pushed to a registry. On a
  machine that lacks it, `nemoclaw onboard --from …` treats the tag as a registry ref and dies
  with *"pull access denied for nemoclaw-finn-base, repository does not exist."* That is not an
  auth problem — it means the one-time base build was skipped. Fix = `./tools/build-finn-base.sh`
  (idempotent) before onboarding. Build **natively** on the target arch (an arm64 image won't run
  on x86_64); to reuse across instances, push to a registry and `docker pull` + re-tag to the
  local name — `nemoclaw onboard` has no `--build-arg` to repoint the base. (SETUP.md → base image.)
- **"Auto-injected" credentials are only injected on a *fresh* onboard.** A bare re-onboard
  leaves the search provider with a placeholder key and its egress preset inactive →
  `web_search` fails with a generic *"fetch failed"*. The setup script now re-applies key +
  egress idempotently — a bare re-onboard is not a no-op.
- **Provider-profile import has no `--force`.** A re-run fails with *"custom provider profile
  'brave' already exists."* It's non-fatal (the profile is a template; the provider *instance*
  holding the key is a separate object and keeps working) — delete the stale template first.
- **A policy preset copied into the blueprint *registers* it** — after that,
  `policy-add --from-file` collides with the name. Pick one flow: register + activate by name,
  or keep the file self-contained under a unique name.
- **Credentials are snapshotted at submit/onboard time** — fix creds *before* the operation
  that consumes them, not after.
- **A resumed onboard skips the OpenClaw config step — and the model pin goes stale.** Switching
  inference provider/model on an existing sandbox via `onboard` + resume leaves
  `agents.defaults.model.primary` at the old value, and the compatible-endpoint smoke check
  fails hard with *"agents.defaults.model.primary is '…'; expected 'inference/<model>'"*. The
  check is right: with the stale pin, every agent turn would request the old model ID from the
  new endpoint. Fix = rewrite the sandbox model config (see setup-finn.sh's `models` layer) and TERM
  the gateway worker; the smoke check then passes unchanged.
  **2026-07-08 stronger finding: the runtime fix cannot survive a recreate.** The skip condition
  is `resume && isOpenclawReady(sandbox)` — a mere gateway-reachability probe — so on ANY
  recreate of a healthy image (e.g. `channels add telegram`) the config-sync step is ALWAYS
  skipped, the fresh sandbox resets to the image's stock pin, and the smoke check fails again —
  `channels add` loops forever. Durable fix = **bake the pin into the base image**
  (`Dockerfile.finn-2026.6.10` step 2c, defaults synced with `.env.sample`); every fresh sandbox
  is then born smoke-clean.
- **NemoClaw ≥ v0.0.73 intercepts `openclaw config set` under `nemoclaw exec`** with *"'openclaw
  config set' cannot modify config inside the sandbox"* (it wants its own rebuild workflow).
  This repo is verified against v0.0.68 — a host-CLI upgrade changed exec semantics out from
  under the setup script and broke the search/fetch/mcp layers. Fix = run config writes via
  direct `docker exec` into the container (setup-finn.sh's `oc()` does this now); the
  interception lives only in the nemoclaw wrapper, not in openclaw itself.

## 7. Scheduling agent work on a pinned platform

Getting three cron loops (daily radar, weekly trends, weekly digest) to run required three
non-obvious mechanics:

1. **`openclaw cron` is a live WS client to the gateway — which is unreachable from the main
   netns.** Registration must run *inside the gateway netns*: find the gateway pid, read its
   auth token, and `nsenter -t <pid> -n` (see `radar/gw-cron.sh`).
2. **`cron add` needs `operator.admin`, but a headless onboard has no admin device to approve
   the upgrade** — the request pends forever. Grant the scope directly in the on-disk device
   table and restart the gateway (`radar/grant-cron-admin.py`, idempotent). This widens no
   egress — it only lets the local operator schedule what the in-process agent could already do.
3. **Scheduled cron turns run context-stripped on this OpenClaw version — the model never calls
   tools**, it just echoes the prompt template, while reporting `delivered:true`. Verify
   scheduled runs by their *effects* (real Notion writes), never by the delivery flag. The only
   path that reliably drives tools is a full agent invocation (`openclaw agent --agent main`).

**The design lesson: strong model authors, weak model executes.** A frontier model wrote the
execution prompts *for* the weaker scheduled executor — literal cadence tables, exact property
names, the query JSON spelled out, few-shot output formats, "if unsure → skip" fallbacks — and
the loop was decomposed to one item per run. Whether that scaffolding is still needed after a
model upgrade is a **cost-per-completed-task** question, not an architecture question.

## 8. Upgrading a version-pinned fork safely

NemoClaw pins OpenClaw and applies string-match source patches that **fail closed** — the right
posture for a security-sensitive base, and it changes how you upgrade:

- The upgrade path is **bump the pinning layer, never the pinned dependency in place**.
- When upstream patch support stops (here: a one-field minified-source delta at OpenClaw
  2026.6.9), write the **minimal tolerance** in the same style as the original patch, keep it
  fail-closed and self-verifying, and **vendor it in the repo**
  (`patches/nemoclaw-2026.6.x-chat-send-runid.patch`) so the base stays reproducible.
- **Prove the full image builds with all patches applied before touching the live agent** — a
  non-destructive build is cheap; a broken live sandbox is not (§5).

## 9. Topology quirks (macOS host-process install)

On this install the OpenShell gateway is a **host process**, not a container — and several
diagnostics assume the Linux container layout:

- `doctor` reports a missing cluster container that never exists here — a false negative; don't
  "fix" it by renaming the sandbox container (its name encodes the UUID every command uses).
- The in-sandbox `inference.local` DNS entry is lost on some restarts, and the auto-repair path
  hunts for that same non-existent container. A clean rebuild re-establishes it.
- Shared-endpoint inference flakiness (`LLM idle timeout`, worker limits) surfaces as *"agent
  run failed before producing a reply"* — **isolate with a no-tool prompt before chasing a
  config bug.** Wiring bugs are deterministic; capacity bugs are not.
- **A host-process gateway that nothing supervises dies with the first reboot** — and the
  sandbox supervisor's crash loop *looks* like a container bug while the real failure is one
  layer up. Run it under **exactly one** OS service manager (systemd on the planned Linux host).
  A macOS launchd LaunchAgent was tried and reverted: it double-managed the gateway against
  `nemoclaw`'s own supervision (and a stray `brew services` gateway), producing an *"Address
  already in use"* restart-storm on `:8080` — the lesson is one owner per gateway, not a second
  supervisor bolted on. Restart gotcha regardless of manager: stopping the outgoing gateway
  `docker stop`s its sandboxes, and restart policy `unless-stopped` never revives an
  explicitly-stopped container — the replacement gateway then loops on *"Sandbox failed to
  become ready (ContainerExited)"* until someone runs `docker start`. A service manager keeps
  the *process* alive, not the *machine* — a lid-closed sleeping laptop still pauses every cron.

## 10. Writing a zero-dep MCP server (craft notes)

- **stdout is the protocol.** All logging goes to stderr, or you corrupt the JSON-RPC stream.
- **Drain before exit.** A piped client half-closes stdin the instant it finishes writing —
  exit on `end` with a call in flight and the last response is dropped. Track pending calls.
- **Secrets in a `0600` file owned by the sandbox user**, read by the server — never in the
  agent config (which would sync/rebuild them around) and never baked into image layers.
- **Read-only by default; write is an explicit opt-in** (`*_WRITE=1` + a write-scoped token).
  The real guard is the **OAuth scope**, not the egress method list — a read-scoped token gets
  403 on writes even where policy allows the verb. Defense in depth, scope first: irreversible
  tools are reachable by prompt-injected web content, so they don't exist unless opted in.
- Zero dependencies (raw stdio JSON-RPC + `fetch`) means no install step through the proxy, no
  SDK version coupling, and a server small enough to audit line-by-line.

## 11. Running scheduled loops on a weak executor + a shared endpoint

- **Symptom: a cron run reports `ok` but wrote nothing.** Root cause: the small executor followed
  a multi-step checklist up to a web search, then treated the search results as the deliverable —
  it output a summary table and stopped before the writes. "Produced a final message" and
  "completed the job" are different things. Fix: HARD RULES at the top of the prompt that define
  done as the exact write calls ("done only after 2× `create_page` + 2× `update_page`"), forbid
  echoing search results, and pin the final output to one line — verified to hold the same model
  on-script under peak load. Verify a loop by reading the datastore it writes, never its status.
- **Symptom: a batch job dies at the cron execution timeout only sometimes.** Root cause: shared
  best-effort inference swings ~20× by time of day (measured ~67 gen tok/s off-peak → ~3 at
  evening peak), so a run that fits its time budget in the morning can't finish the same work at
  night. Fixes, in order: shard the batch (here: all-topics → two-topics-per-run on a date-cursor
  rotation), schedule into the fast lane, and only then consider a served-with-SLO endpoint.
- **Observability traps:** the gateway logs a `message processed` line only for FAILED cron runs —
  success is visible only in `cron_run_logs` (state SQLite) or the outbound delivery; and a manual
  `cron run` can sit queued ~15–19 min before executing, so trigger-to-finish wall clock
  overstates run cost. Watchers should poll the run-log table, not the log file.

## 12. Gateway device pairing on a headless sandbox (rebuild → `pairing required` lockout)

Validated the hard way on 2026-07-08 (EC2 bring-up; NemoClaw v0.0.73 host CLI).

- **Any rebuild/recreate wipes `devices/paired.json` — and with it every gateway client's
  trust.** Every gateway-WS CLI call (`agent`, `cron`, `channels status`, `pairing`, the setup
  layers) then fails with *"pairing required: device is not approved yet"*, and `nemoclaw
  <name> agent` **silently falls back to the EMBEDDED agent** — a passing PONG proves nothing
  about the gateway path (§1's lesson again). `gateway.controlUi.dangerouslyDisableDeviceAuth`
  does NOT help: the gateway honors it only for Control-UI connections (`isControlUi` in the
  connect handler), never for CLI clients — don't weaken it.
- **The sanctioned approver is nemoclaw-start's auto-pair watcher** (the long-lived in-container
  `python3 -` child). It polls `openclaw devices list` gateway-pinned and approves allowlisted
  pending requests via OpenClaw's local on-disk fallback. But its own list call is a gateway
  client too — with NOTHING paired it is itself rejected, so after a rebuild it can't bootstrap
  the first device. Once one CLI device is paired it works again (including scope upgrades).
- **`openclaw devices approve <id>` cannot converge for a FIRST-TIME pairing.** Each invocation
  makes two gateway connects (list-context + approve) requesting different scope sets, and each
  connect REPLACES the pending request with a fresh requestId — the id you pass is always stale,
  and the same-device-replacement rescue path requires an already-paired device. Bootstrap by
  calling the implementation directly on the on-disk store instead:
  `tools/approve-cli-device.sh` (node → OpenClaw's `approveDevicePairing()` with
  `callerScopes: [operator.admin]`, reading the live pending id in-process).
- **`~/.nemoclaw/rebuild-backups` strip private keys** (`privateKeyPem` is a 23-char stub in
  every backup), so a workspace **restore plants a corrupt device identity**. OpenClaw's
  identity self-check then silently generates a THROWAWAY identity per CLI invocation:
  `devices/pending.json` floods with one-off deviceIds (~1 per poll), no approval can ever
  stick, and the watcher — once unblocked — will mass-approve the junk. Fix = delete
  `identity/device.json` + `identity/device-auth.json`, let the next CLI run mint a fresh
  persistent identity, approve that one, then `openclaw devices remove` the junk devices.
- **Don't chmod `.openclaw` while debugging.** nemoclaw's exec wrapper enforces
  `.openclaw`=2770 setgid / `openclaw.json`=660 and runs a perms normalizer after every exec;
  if the in-container helper (`/usr/local/lib/nemoclaw/normalize_mutable_config_perms.py`) is
  missing — the case when the image was built under an older nemoclaw — **every `nemoclaw exec`
  exits 1 even though the inner command succeeded**, which silently kills `set -e` setup scripts
  mid-run. Copy the helper in from `~/.nemoclaw/source/scripts/lib/` or keep the modes intact.

## 13. A reasoning model needs output headroom (`maxTokens` starves the visible answer)

Validated 2026-07-13 (the `finn-weekly-digest` cron failure).

- **Symptom: a cron run dies with "⚠️ Agent couldn't generate a response … some tool actions
  may have already been executed", and the gateway log shows
  `incomplete turn detected … stopReason=length`.** The run's final assistant turn in the
  session jsonl is the tell: `output: 8192, reasoningTokens: 8191, content: []` — the model
  spent the ENTIRE `maxTokens` budget thinking and had zero tokens left for visible text.
- **Root cause: kimi-k2.6 streams its reasoning in-band**, inside the same completion budget as
  the answer, even with `thinkingLevel: off` and the model registered `reasoning: false` (the
  endpoint reasons regardless; the harness knobs don't reach it). With `maxTokens: 8192` any
  turn that thinks long — e.g. synthesizing a digest from four fat Notion query results — hits
  `stopReason=length` mid-think. A length-stop is NOT retried by the reasoning-only-turn
  continuation machinery (that path triggers on complete turns with no visible text), so it
  surfaces straight to the user.
- **Fix: give the completion budget ~4× headroom** — `INFERENCE_MAX_TOKENS=32768` (context
  window 262144 has plenty of room). Two config traps while applying it:
  - `layer_models` and the Dockerfile bake used to be **append-only** (`any(id==mid) or
    append(...)`) — re-running setup with a new `INFERENCE_MAX_TOKENS` silently changed
    nothing on an already-registered model. Both now replace-or-append.
  - For the LIVE sandbox, patch `models.providers.inference.models[].maxTokens` in
    `openclaw.json` and do a full gateway restart (§2's rule: model config loads only on
    restart).
- **Triage recipe:** failed run's sessionId is in the `message processed … outcome=error` log
  line → read `/sandbox/.openclaw/agents/main/sessions/<sessionId>.jsonl` → last assistant
  entry's `stopReason`/`usage` tells you length-starvation (this §) vs rate-limit (429, §11)
  vs reasoning-only (§11). Before retrying, check the transcript's tool calls: the digest run
  was read-only Notion queries, so a manual `gw-cron.sh cron run <jobId> --wait` re-delivery
  was safe.
