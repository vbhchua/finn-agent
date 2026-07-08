*↑ [[architecture/_index|Architecture index]] · part 1 of 6 · next: [[02-trust-and-egress|Trust boundaries & egress]] →*

# 1. What finn is

A single OpenClaw **sandbox agent** ("finn") for NVIDIA DevRel research, deployed via
**NemoClaw** on **OpenShell**. On v0.0.67 it is a **stock `nemoclaw onboard` sandbox** —
no custom image, no `finn-base:local` build — plus a handful of **runtime** tweaks
(`setup-finn.sh`): enable the bundled Firecrawl extension for `web_fetch`, add the Telegram
channel, and (optionally) layer the calendar MCP add-on. Web *search* works out of the box
(brave). The gateway authenticates because the **stock base now ships `nemoclaw-start`**.

```
host (macOS)                         sandbox container (uid 998 "sandbox")
┌────────────────────────┐          ┌───────────────────────────────────────────┐
│ openshell-gateway      │          │ ENTRYPOINT: nemoclaw-start (STOCK base)     │
│ (host process)         │          │   ├─ generates OPENCLAW_GATEWAY_TOKEN       │
│ nemoclaw CLI           │  manages │   ├─ writes /tmp/nemoclaw-proxy-env.sh      │
│ openshell provider …   │ ───────▶ │   └─ launches openclaw gateway :18789      │
│                        │          │         ├─ embedded agent (Nemotron)       │
│ FIRECRAWL_API_KEY ─────┼─runtime─▶│         ├─ brave (web_search, built in)     │
│ TELEGRAM_BOT_TOKEN     │  inject  │         ├─ firecrawl (web_fetch, bundled)   │
│                        │          │         └─ telegram bridge (pairing)        │
└────────────────────────┘          └───────────────────────────────────────────┘
                                        │ all external egress
                                        ▼
                              OpenShell L7 proxy (deny-by-default)
                              ├─ inference.local      → NVIDIA NIM (Nemotron)
                              ├─ api.search.brave.com  (brave preset, stock)
                              ├─ api.firecrawl.dev:443 (firecrawl preset)  ◀── the one
                              └─ api.telegram.org      (telegram policy)       added host
```

| Component | Choice | Source |
|---|---|---|
| Base image | **stock** `ghcr.io/nvidia/nemoclaw/sandbox-base` (ships `nemoclaw-start`) | `nemoclaw onboard` (no custom build) |
| Custom layer | **none** — Firecrawl is a *bundled* extension, enabled at runtime | `setup-finn.sh` |
| Inference | NVIDIA NIM `nvidia/nemotron-3-super-120b-a12b` via `inference.local` | `nemoclaw.yaml` |
| Web search | **brave** (built in; `BRAVE_API_KEY` auto-injected by onboard) → `api.search.brave.com` | stock |
| Web fetch | bundled **firecrawl** extension → `api.firecrawl.dev` | `setup-finn.sh` + `fixes/firecrawl.yaml` |
| Egress policy | deny-by-default L7 proxy + the `firecrawl` preset | OpenShell + `fixes/firecrawl.yaml` |
| Control channel | Telegram, `dmPolicy=pairing` | `nemoclaw finn channels add telegram` |

> [!note] Alt — Exa search instead of brave
> Exa is also a **bundled** stock extension (`api.exa.ai`). To swap the *search* provider,
> enable it and set `tools.web.search.provider=exa` (apply `fixes/exa.yaml` for egress);
> fetch stays on Firecrawl. Same trust boundaries; one extra egress host. The old custom
> Exa *build* is retired (preserved in git history) — no image build is needed now.

> [!note] Add-on — Outlook / live.com calendar (via MCP)
> An optional **runtime** add-on (setup-finn.sh's `calendar` layer) registers a zero-dep Microsoft
> Graph **MCP server** (`mcp/ms-calendar-mcp.mjs`) giving the agent calendar tools —
> **read-only by default**, with create/update/delete behind an explicit `MS_CALENDAR_WRITE=1`
> opt-in (+ a `Calendars.ReadWrite` token). It adds two egress hosts (`graph.microsoft.com` +
> `login.microsoftonline.com`, `fixes/ms-calendar.yaml`) and authenticates a **personal**
> Microsoft account with a **delegated OAuth refresh token** (no app-only creds exist for
> consumer accounts). It is a **tool the agent calls**, not a new inbound channel. Security
> treatment in [[04-add-on-security#6. Calendar add-on — Graph calendar via MCP|§4 item 6]].

> [!note] Add-on — Notion (via MCP)
> A second optional **runtime** add-on (setup-finn.sh's `notion` layer) registers a zero-dep Notion REST
> **MCP server** (`mcp/notion-mcp.mjs`) giving the agent Notion tools — **read-only by default**
> (search / read pages + databases), with create/update/append behind an explicit `NOTION_WRITE=1`
> opt-in. It adds one egress host (`api.notion.com`, `fixes/notion.yaml`) and authenticates with a
> Notion **internal-integration token** (a static bearer; the *hosted* `mcp.notion.com` MCP is
> OAuth/browser-only, so unusable for a headless sandbox). The integration sees **only the
> pages/databases explicitly shared with it** — a natural least-privilege boundary. Like calendar,
> it is a **tool the agent calls**, not a new inbound channel. Security treatment in
> [[04-add-on-security#7. Notion connector — via MCP|§4 item 7]].

---

*↑ [[architecture/_index|Architecture index]] · part 1 of 6 · next: [[02-trust-and-egress|Trust boundaries & egress]] →*
