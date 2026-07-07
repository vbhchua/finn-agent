<div align="center">

<pre>
███████╗██╗███╗   ██╗███╗   ██╗
██╔════╝██║████╗  ██║████╗  ██║
█████╗  ██║██╔██╗ ██║██╔██╗ ██║
██╔══╝  ██║██║╚██╗██║██║╚██╗██║
██║     ██║██║ ╚████║██║ ╚████║
╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═══╝
</pre>

<h3>🦈&nbsp; the relentless AI-events hunter for Singapore</h3>

<p>
<em>A sandboxed <a href="https://openclaw.ai">OpenClaw</a> agent on <b>NVIDIA&nbsp;NemoClaw&nbsp;·&nbsp;OpenShell</b><br/>
that never stops scouring for AI conferences, speakers &amp; trends —<br/>
and pings you the moment something moves.</em>
</p>

<p>
<a href="https://github.com/NVIDIA/NemoClaw"><img src="https://img.shields.io/badge/NVIDIA-NemoClaw%20%C2%B7%20OpenShell-76B900?logo=nvidia&logoColor=white" alt="NVIDIA NemoClaw · OpenShell"></a>
<a href="https://openclaw.ai"><img src="https://img.shields.io/badge/OpenClaw-2026.6.10-1f6feb" alt="OpenClaw 2026.6.10"></a>
<img src="https://img.shields.io/badge/inference-Kimi%20K2.6%20%C2%B7%20compatible--endpoint-76B900" alt="inference: Kimi K2.6 via NemoClaw compatible-endpoint">
<img src="https://img.shields.io/badge/fallback-OpenRouter-1f6feb" alt="fallback: OpenRouter">
<img src="https://img.shields.io/badge/egress-deny--by--default-critical" alt="deny-by-default egress">
<img src="https://img.shields.io/badge/MCP-calendar%20%26%20notion-8957e5" alt="MCP: calendar & notion">
<a href="https://core.telegram.org/bots"><img src="https://img.shields.io/badge/control-Telegram-26A5E4?logo=telegram&logoColor=white" alt="Telegram control"></a>
<a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue" alt="Apache 2.0"></a>
</p>

<code>folder seed&nbsp;→&nbsp;host bootstrap&nbsp;→&nbsp;Notion = source of truth&nbsp;→&nbsp;finn loops&nbsp;→&nbsp;Telegram</code>

</div>

---

## ✨ What it does

|   |   |
|---|---|
| 🔎&nbsp; **Hunts** | Web research via **brave** search + **Firecrawl** full-page fetch — reads any page through one egress-locked endpoint, no per-site allowlist. |
| 🗓️&nbsp; **Acts** | Read/write your **Outlook calendar** & **Notion** through zero-dep stdio **MCP** servers (writes opt-in, scope-gated). |
| 📡&nbsp; **Watches** | A proactive **conference-radar** loop keeps SG/APAC AI events, speakers & trends fresh in Notion. |
| 🔔&nbsp; **Pings** | Material changes — new keynote, NVIDIA confirmed, date/venue shift — land on **Telegram**. |
| 🛡️&nbsp; **Contained** | Runs **non-root** in a **deny-by-default** OpenShell sandbox; every tool call is egress-policed. |

## 🚀 Quick Setup — the golden path

> **This is the stack finn actually runs**: OpenClaw **2026.6.10**, **Kimi K2.6** inference
> through the gateway's compatible-endpoint (OpenRouter as an optional direct fallback), web
> search + full-page fetch, Telegram control, the calendar + Notion MCP servers, and the radar
> loops. All six steps are standard — run them in order. Secrets live in a gitignored **`.env`**
> (template: `.env.sample`); every `./…` script is idempotent (re-run after any rebuild).
> One-time prerequisites (the 2026.6.10 base build + vendored NemoClaw patch, the Entra app,
> the Notion integration) and troubleshooting live in **[SETUP.md](SETUP.md)**.

```bash
set -a; . ./.env; set +a                    # load all keys (.env.sample lists them)

# 1. Sandbox — the OpenClaw 2026.6.10 image (needs NemoClaw v0.0.68 + the vendored
#    patch in patches/; one-time base build → SETUP.md):
nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn

# 2. Full-page fetch (Firecrawl) + Brave search key + Telegram bot — one shot:
./setup-finn.sh                             # uses FIRECRAWL_API_KEY · BRAVE_API_KEY · TELEGRAM_BOT_TOKEN

# 3. Outlook / live.com calendar (refresh token minted once via tools/ms-graph-login.mjs):
MS_CALENDAR_WRITE=1 ./runmod-finn-live.sh   # drop MS_CALENDAR_WRITE for read-only

# 4. Notion connector (internal integration, hub pages shared with it):
NOTION_WRITE=1 ./runmod-notion-live.sh      # drop NOTION_WRITE for read-only

# 5. Conference Radar + Topic Trends + weekly digest (reuses NOTION_TOKEN):
./runmod-conference-radar-live.sh           # DRYRUN=1 also runs the radar once

# 6. Model providers — Kimi K2.6 primary through the gateway's compatible-endpoint
#    (MOONSHOT_API_KEY is registered gateway-side at onboard); OpenRouter direct
#    fallback activates when OPENROUTER_API_KEY is set:
./runmod-models-live.sh
```

> **Host resilience (macOS):** `./tools/install-gateway-launchagent.sh` puts the host
> `openshell-gateway` under launchd (RunAtLoad + KeepAlive) so a reboot or crash can't
> silently take the whole stack down.

> **Minimal variant** (not the path finn runs): a stock `nemoclaw onboard --name finn` alone
> gives a working search-only agent — kept in [SETUP.md](SETUP.md) for reference.

**→ Full guide — prerequisites, MCP internals, Exa variant, manual steps, and troubleshooting: [SETUP.md](SETUP.md).**

**→ The hard-won gotchas — the MCP egress trap, netns false-negatives, lifecycle & recovery: [docs/LEARNINGS.md](docs/LEARNINGS.md).**

---

## 🙏 Credits

finn is derived from NVIDIA's **[NemoClaw for OpenClaw blueprint](https://build.nvidia.com/nvidia/nemoclaw-for-openclaw/nemoclawcard)** —
the sandboxed-agent scaffold (OpenShell runtime, deny-by-default egress, managed
`inference.local` routing) that everything here builds on. This repo adds the DevRel research
stack: the Firecrawl fetch layer, the calendar + Notion MCP servers, the conference-radar
loops, and the model-provider switch (Kimi K2.6 primary via the gateway's compatible-endpoint,
OpenRouter as a direct fallback).
