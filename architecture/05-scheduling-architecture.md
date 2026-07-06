*↑ [[architecture/_index|Architecture index]] · part 5 of 6 · ← [[04-add-on-security|Add-on security]] · next: [[06-net-posture|Net posture]] →*

# 5. Proactive loops — the scheduling architecture

> [!summary] The pattern, in one line
> finn's proactive layer (Conference Radar + Topic Trends + the Monday digest) runs on
> **state-indirection + producer→consumer chaining**: the changing work-list lives in a
> **shared store**, never in a cron prompt; each scheduled run is a *fixed* prompt that reads
> the current state at fire time; **earlier loops write state that later loops read.** This is
> partly forced (it routes around hard limits in OpenClaw's scheduler, below) and partly just
> the right shape for "a list that changes day to day."

## 5.1 Why the obvious approach doesn't work — OpenClaw cron limits

OpenClaw's cron is a recurring **scheduler**, not a loop engine. You cannot tell it *"every
day, loop over the current topic list and update each item."* The relevant limits (the first
three are general OpenClaw; the last two are finn-specific, verified against the pinned build —
see [docs/LEARNINGS.md](../docs/LEARNINGS.md) §7 + PROGRESS.md 2026-06-25):

| Limit | Consequence for "a list that changes daily" |
|---|---|
| **Fixed prompt at creation** — no templating, no variable/payload substitution into the prompt (even a webhook's JSON body isn't spliced in) | You can't bake "today's topics" into a job; changing the list would mean editing the job every day |
| **No native iteration** — each fire is one independent run of one prompt | The scheduler won't fan out over a collection; any looping must happen *inside* a run or *outside* cron |
| **No native job chaining** — "run B after A finishes" is only a proposal (RFC #28584); "every cron job is independent" | Producer→consumer **ordering must be enforced by the clock**, not a dependency edge |
| **finn-specific (pinned OpenClaw 2026.5.27): scheduled turns run context-stripped → the model never calls tools** (BLOCKER 1) | Even a fixed-prompt job can't *do* anything on a schedule; the only path that drives tools is host-scheduled `openclaw agent --agent main` (full AGENTS.md/TOOLS.md bootstrap) |
| **finn-specific: the weak executor (Nemotron) reliably completes only *simple, single-item* runs** (BLOCKER 2) | A "loop over 15 topics in one run" prompt fails — it reads/searches but garbles or skips the writes |

Net: finn (1) schedules on the **host** (launchd/cron), not OpenClaw cron, and invokes the
full-bootstrap agent path (`radar/run-job.sh` → `openclaw agent --agent main`); (2) keeps the
dynamic list in a **store the run reads at fire time**; and (3) decomposes any iteration into
**one item per run**.

> [!tip] On an OpenClaw/NemoClaw upgrade, BLOCKER 1 collapses — BLOCKER 2 does not
> Current OpenClaw has **command jobs** (`--command`/`--command-argv`), so a newer build (shipped
> via a NemoClaw bump — bumping OpenClaw alone un-bundles firecrawl/exa, see PROGRESS.md 2026-06-24)
> could schedule `--command radar/run-job.sh` *inside* OpenClaw cron and drop the host scheduler.
> That fixes the **plumbing** only: the weak-executor limit (BLOCKER 2) is the model, not the
> scheduler, so the one-item-per-run decomposition below survives the upgrade unchanged.

## 5.2 The strategy — dynamic list in a store, read at run time, written by an earlier loop

Two moves, both pure indirection:

- **State-indirection (solves "the list changes daily").** The cron prompt is fixed and
  generic — *"read the current watch-list from the store and act on what's due."* The
  **list itself lives outside the prompt**, in a store the run reads when it fires. Edit the
  store, not the job; tomorrow's run picks up the change for free.
- **Producer→consumer chaining (solves "no native chaining").** An earlier loop **writes**
  state; a later loop **reads** it. Ordering is enforced by **schedule offsets** (producer
  early, consumer later, with a gap), because there is no native "run after." If the producer
  is late or fails, the consumer sees stale/empty state and says so — at-least-once, never a
  silent dependency break.

## 5.3 How finn implements it today — Notion as the shared store

finn uses **Notion as the shared store** rather than a flat file. Mapping the pattern onto the
three existing loops (`radar/prompts/{conf-radar,topic-trends,weekly-digest}.md`):

| Pattern role | finn realization |
|---|---|
| **The dynamic list** | `📅 AI Events — Singapore` (events) + `finn · Topics` (trend watch-list) DBs |
| **The "what's due now" selector** (what makes it change day to day) | a Notion **server-side date filter** on `Next check due` (+ a `next_month` proximity backstop) — adaptive cadence keyed off `Tier` × days-until-`Date` |
| **Producer loops** (write state) | **conf-radar** (daily) writes `Last checked` / `Next check due` / `Latest change` per event; **topic-trends** (weekly) writes rows into `finn · Trend snapshots` |
| **Consumer loop** (reads what producers wrote) | the **Monday digest** reads the events DB's recent `Latest change`s + the latest trend snapshots + `Status=Proposed` events, and composes the one Telegram message |

So finn **already does producer→consumer chaining** — the digest is a consumer of the radar
and trend producers. Why Notion and not a flat queue file as the durable store:

- it's **already an allowed egress host** (`fixes/notion.yaml`) — no new trust-boundary surface;
- it gives **durable, human-curatable** cross-run state — Victor edits the watch-list / approves
  `Proposed` events in the UI, which *is* "changing the list day to day";
- it **survives a sandbox rebuild**, whereas anything under `/sandbox` is lost on a full `onboard`;
- the consumer (digest) reads it **for free** — the store doubles as the digest's data source.

## 5.4 Applying the pattern to unblock Topic Trends *(PROPOSED design — not yet built)*

The still-broken loop is **topic-trends**: it tries to process all ~15 topics in **one**
Nemotron run and fails (BLOCKER 2) — the same way the *original* multi-event conf-radar failed
before it was rewritten to **one event per run** (proven working 2026-06-25). The fix is to
apply the same producer→consumer decomposition, but make the *iteration itself* deterministic
and host-side via a **two-tier store** (durable state in Notion; a transient per-cycle **work
queue** in a file):

1. **Producer / dispatcher — `radar/dispatch.sh` *(proposed, not built)*, runs first each cycle, no model.**
   Cheap deterministic host code: query the dynamic list for what's due — `finn · Topics`
   rows whose `Next check due ≤ today` (or not yet snapshotted this week), or the
   `seed-topics.json` fallback — and **stage one filled prompt per due item** as
   `/sandbox/.cache/radar/queue/topic-<slug>.msg` (reusing the existing `{{…_DB}}`/`{{CHAT_ID}}`
   staging convention). This *is* the "earlier loop writes a dynamic file": the queue is
   regenerated every cycle from the current list.
2. **Consumer — one item per run via the proven path.** The host scheduler fires
   `radar/run-job.sh` once per queued `.msg` (or `run-job.sh` pops one item per invocation).
   Each run executes a **rigid single-item checklist** (1 query → 1 search → 1
   `finn · Trend snapshots` write → mark the topic's `Last snapshot`/`Next check due` in
   `finn · Topics`), then the item is removed from the queue. Nemotron only ever sees **one
   topic** → it succeeds, exactly as the one-event conf-radar does.
3. **Consumer of consumers — the digest** reads the snapshots the per-topic runs wrote (already
   built; unchanged).

**Why the queue file in addition to the Notion date-filter:** the filter already makes the list
dynamic, but the weak model can't be trusted to *iterate* even the filtered set in one run. The
queue moves the iteration **off the model and onto deterministic host code** — each model run is
atomic and single-item. Notion stays the durable source of truth and the digest's read source;
the queue is throwaway per-cycle dispatch scratch (rebuilt next cycle, so its loss on rebuild
doesn't matter). This generalizes conf-radar too: a dispatcher that enqueues *due events* makes
"which event does this run handle?" a host decision instead of asking the weak model to pick.

## 5.5 Ordering, idempotency, failure

- **Ordering = schedule offsets, not dependencies** (no native chaining): dispatcher → per-item
  consumers → digest, each with a time gap. A late/failed dispatcher means consumers find an
  empty queue and the digest notes the gap — degraded, not broken.
- **Idempotent by construction:** the dispatcher only enqueues items whose `Next check due ≤
  today` / not-snapshotted-this-week, so a re-run (e.g. after a rebuild re-installs the schedule)
  doesn't double-process. The Notion bootstrap is already locate-by-search/add-only.
- **At-least-once:** an item whose consumer run fails simply stays due, so the next cycle's
  dispatcher re-enqueues it; the digest reports whatever actually landed. (Mind the general
  OpenClaw-cron reliability caveats too — recurring jobs have been reported to silently not fire;
  verify the *host* schedule actually triggers, not just that `run-job.sh` works by hand.)

## 5.6 Security framing

This is a **scheduling/decomposition mechanism — it does not widen the trust boundary.** The
proposed dispatcher is the same *host-side, no-new-capability* shape as `radar/notion-bootstrap.mjs`
([[04-add-on-security#8. Conference Radar + Topic-Trend cron loops|§4 item 8]]): it runs on the
laptop / as a host job, touches no egress, and only stages files + reads Notion. The per-item
consumer runs reuse exactly the boundaries of [[03-security-analysis|§4 item 1]] (web read) and
[[04-add-on-security#7. Notion connector — via MCP|§4 item 7]] (Notion write) — no new egress host,
no tool the agent couldn't already call interactively, no new inbound surface (the queue is
host-internal scratch, not a channel). Output is still **human-reviewed in the Monday digest**
before Victor acts, and discovered events still land as `Proposed`. The indirection narrows risk
if anything — host code, not the weak model, decides *which* items run.

---

*↑ [[architecture/_index|Architecture index]] · part 5 of 6 · ← [[04-add-on-security|Add-on security]] · next: [[06-net-posture|Net posture]] →*
