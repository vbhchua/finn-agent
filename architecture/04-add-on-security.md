*↑ [[architecture/_index|Architecture index]] · part 4 of 6 · ← [[03-security-analysis|Security analysis]] · next: [[05-scheduling-architecture|Scheduling architecture]] →*

# 4 (cont.). Security of the optional add-ons

These are **items 6–8 of the §4 [[03-security-analysis|security analysis]]** — the optional
runtime add-ons. Each applies only if you ran the corresponding `runmod-*` script; a base
finn has none of them.

## 6. Calendar add-on — Graph calendar via MCP

*Applies only if `runmod-finn-live.sh` was run.*

> [!warning] Read by default; create/update/delete is an opt-in with a real blast radius
> The MCP server lets the agent read calendar events + the calendar list, and — **when
> `MS_CALENDAR_WRITE=1` and a `Calendars.ReadWrite` token are supplied** — create, modify, and
> **delete** events. Because the agent also reads arbitrary web pages
> ([[03-security-analysis|item 1]]), prompt-injected content could in principle coax it into
> exfiltrating the schedule **or, in write mode, creating or deleting events**. `delete_event`
> is irreversible. This is exactly why **write is off by default** and gated behind an explicit
> flag + a separately-scoped token. Bounded by: least-privilege egress (two hosts), no mailbox
> access, and the research-only task scope.

The read-vs-write guard is layered, **scope-first** — not the egress method list:
- **OAuth scope is the authoritative guard.** A *personal* MS account can't use app-only client
  credentials, so auth is a delegated **refresh token**. Mint it `Calendars.Read` (read-only) or
  `Calendars.ReadWrite` (read/write) — a Read-scoped token gets **403** from Graph on any write
  *even if the network policy allows the method*. To change modes you must re-mint; a read-only
  token can't be silently upgraded. The token is minted off-box (device-code on the laptop) and
  injected at runtime into a **`0600` sandbox-only file** (`/sandbox/.config/ms-calendar.env`),
  never into the image, repo, or `openclaw.json` — same posture as the Firecrawl key.
- **Tool exposure is the second gate.** Write tools (`create_event`/`update_event`/`delete_event`)
  are only registered when `MS_CALENDAR_WRITE` is truthy — read-only deployments expose 5 tools,
  the write tools simply don't exist for the model to call.
- **Least-privilege egress.** `fixes/ms-calendar.yaml` opens only `graph.microsoft.com` +
  `login.microsoftonline.com` (a deliberate subset of the built-in `outlook` preset, which also
  opens two office.com mailbox/EWS hosts we don't need). The Graph host allows GET/POST/PATCH/DELETE
  so one preset serves both modes — safe because scope+exposure, above, are the real guards. Still
  deny-by-default for every other host.
- **The calendar tool does NOT bypass the egress firewall — it goes *through* it.** The MCP server
  runs as a child of the gateway in the same proxy-only netns, and (because OpenClaw scrubs its env)
  **self-bootstraps the gateway's egress on startup**: it re-execs with `HTTPS_PROXY` +
  `NODE_EXTRA_CA_CERTS` (the OpenShell TLS-interception CA) read from its gateway parent's
  `/proc/<ppid>/environ`. So every calendar request is **routed through the same L7 NemoClaw proxy and
  governed by the same `ms-calendar` network policy** as all other egress — not a side channel. (This
  is why a direct, un-proxied `fetch()` from the child is *blocked*; see [docs/LEARNINGS.md](../docs/LEARNINGS.md) §1, the egress trap.)
- **Local, auditable tool code.** The MCP server is **our** zero-dependency file (raw stdio
  JSON-RPC + `fetch`) — no `@modelcontextprotocol/sdk`, no third-party MCP package pulled into
  the trusted gateway process. Less un-pinned supply chain than the Firecrawl plugin, not more.
- **No new inbound surface.** It's a *tool the agent calls*, not a messaging channel — it adds
  no new way to reach or command the agent (Telegram `dmPolicy=pairing` is still the only inbound).

## 7. Notion connector — via MCP

*Applies only if `runmod-notion-live.sh` was run.*

> [!warning] Read by default; create/update/append is an opt-in
> The MCP server lets the agent **search and read** Notion pages/databases, and — **when
> `NOTION_WRITE=1` and an integration with write capability are supplied** — `create_page`,
> `update_page` (incl. archive), and `append_blocks`. Because the agent also reads arbitrary web
> pages ([[03-security-analysis|item 1]]), prompt-injected content could in principle coax it into
> reading the workspace or, in write mode, creating/altering pages. There is **no destructive
> delete** (archiving is a reversible `PATCH archived:true`), but write is still off by default and
> gated behind an explicit flag. Bounded by: the integration seeing **only shared pages**,
> least-privilege egress (one host), and the research-only task scope.

The read-vs-write guard is layered, **scope-first** — not the egress method list:
- **The Notion integration's capability + sharing is the authoritative guard.** Unlike the calendar's
  whole-calendar token, a Notion integration sees **only the pages/databases explicitly shared with
  it** — a natural least-privilege boundary set in the Notion UI. Its *capability* (Read content vs
  Insert/Update content) is the real write gate: a read-only integration gets **403** from Notion on
  any write *even if the network policy allows the method*. The token is a **static internal-integration
  secret** (`ntn_…`) — simpler than the calendar's delegated-OAuth refresh dance, no token endpoint —
  injected at runtime into a **`0600` sandbox-only file** (`/sandbox/.config/notion.env`), never in the
  image, repo, or `openclaw.json`. (We deliberately avoid Notion's *hosted* `mcp.notion.com` MCP: it's
  OAuth/browser-only and can't drive a headless sandbox.)
- **Tool exposure is the second gate.** Write tools (`create_page`/`update_page`/`append_blocks`) are
  only registered when `NOTION_WRITE` is truthy — read-only deployments expose 7 tools, the write tools
  simply don't exist for the model to call.
- **Least-privilege egress.** `fixes/notion.yaml` opens only `api.notion.com` (GET/POST/PATCH — Notion
  has no DELETE). Still deny-by-default for every other host.
- **The Notion tool goes *through* the egress firewall, not around it.** Same as calendar: the MCP
  server runs as a child of the gateway in the proxy-only netns and (because OpenClaw scrubs its env)
  **self-bootstraps the gateway's egress** by re-execing with `HTTPS_PROXY` + `NODE_EXTRA_CA_CERTS`
  pulled from its parent's `/proc/<ppid>/environ`. Every Notion request is routed through the same L7
  proxy and governed by the `notion` policy (see [docs/LEARNINGS.md](../docs/LEARNINGS.md) §1, the egress trap).
- **Local, auditable tool code.** `mcp/notion-mcp.mjs` is **our** zero-dependency file (raw stdio
  JSON-RPC + `fetch`) — no `@modelcontextprotocol/sdk`, no third-party Notion MCP package pulled into
  the trusted gateway process.
- **No new inbound surface.** A *tool the agent calls*, not a messaging channel.

## 8. Conference Radar + Topic-Trend cron loops

*Applies only if `runmod-conference-radar-live.sh` was run.*

> [!warning] Autonomous, scheduled, web-reading + Notion-writing turns
> The three gateway cron jobs run **unattended** agent turns that read **arbitrary web pages**
> ([[03-security-analysis|item 1]]) and **write to Notion** (item 7) on a schedule — no human in
> the loop at fire time. So prompt-injected web content could, in principle, steer a scheduled run
> to write misleading rows or over-propose events. Bounded by: it reuses the **same** capabilities
> and trust boundaries as items 1 & 7 (no new egress host, no new tool the agent couldn't already
> call interactively); Notion writes are still scoped to **shared pages only** with **no destructive
> delete**; the output is **human-reviewed** in the Monday digest before Victor acts; and discovered
> events land as `Proposed`, not as confirmed/Upcoming. No new inbound surface — cron is
> gateway-internal scheduling, not a channel.

Two setup-time elevations are worth calling out explicitly (both **local, neither widens egress**):
- **DB creation/schema changes are done host-side**, not by the agent. `radar/notion-bootstrap.mjs`
  runs on the laptop with `NOTION_TOKEN`; the in-sandbox agent has no `create_database`/schema tool.
  This **shrinks** the agent's write surface — it can only ever read/update *rows* in pre-made DBs.
- **The cron CLI is granted `operator.admin`** in the gateway's on-disk device table
  (`radar/grant-cron-admin.py`). This is a **local operator** capability — it lets the laptop schedule
  cron jobs, the same thing the in-process agent can already do via its own `cron` tool. It does **not**
  touch the egress firewall, the proxy, or what hosts are reachable; it is orthogonal to the network
  trust boundary. (It exists only because a headless `nemoclaw onboard` leaves no admin device to
  approve the upgrade — see [docs/LEARNINGS.md](../docs/LEARNINGS.md) §7.)

> [!note] How these loops are *scheduled* and *decomposed* is its own topic
> The security treatment above covers *what the loops can touch*. The **scheduling architecture**
> — why they don't use OpenClaw cron the obvious way, where the dynamic work-list lives, and how
> the loops hand off state to each other — is [[05-scheduling-architecture|§5 Proactive loops]].

---

*↑ [[architecture/_index|Architecture index]] · part 4 of 6 · ← [[03-security-analysis|Security analysis]] · next: [[05-scheduling-architecture|Scheduling architecture]] →*
