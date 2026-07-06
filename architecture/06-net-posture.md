*↑ [[architecture/_index|Architecture index]] · part 6 of 6 · ← [[05-scheduling-architecture|Scheduling architecture]]*

# 6. Net posture

On v0.0.67, finn is **even closer to a stock NemoClaw sandbox than before** — it now *is*
the stock image — with one deliberate capability expansion: **the agent can read any public
web page** (via Firecrawl `web_fetch`; search stays on stock brave) rather than only
allowlisted hosts. That trade is the entire reason Firecrawl was chosen — it removes the
per-site allowlist toil for a research agent — and it is bounded by the still-intact egress
proxy (which governs what the sandbox can *connect to* directly) and by the read-only,
research-only task scope. `proxy.loopbackMode=gateway-only` *looks* security-relevant but
isn't on the egress axis — it's a functional requirement (loopback gateway RPC), now the
stock default, that leaves the external egress firewall untouched. The two optional **MCP
add-ons** (calendar, Notion) extend the agent with *tools it calls* — each read-only by default,
write behind an opt-in, least-privilege egress through the same proxy, and our own auditable
zero-dep code — adding capability without adding inbound surface
([[04-add-on-security|§4 items 6–7]]).

> [!tip] If hardening for a higher-trust deployment
> 1. Self-host Firecrawl on a policed internal host to regain egress control over reads.
> 2. Pass the Firecrawl key via env/stdin, not a shell-expanded arg.
> 3. Leave `codeMode` off (the default) unless you switch to a model that can drive it.
> 4. Keep the loopback default (`gateway-only`) — do NOT override it to `"proxy"`: on this
>    host-process topology that blocks the gateway's own loopback RPC (SSRF hardening) and
>    floods the logs with `127.0.0.1:18789` denials. It does not affect external egress.
> 6. If the calendar add-on is enabled, keep it **read-only** (mint a `Calendars.Read` token,
>    leave `MS_CALENDAR_WRITE` unset) unless the agent genuinely needs to create/delete events —
>    the agent reads attacker-influenceable web content, and `delete_event` is irreversible.
> 7. If the Notion connector is enabled, share **only the pages/databases the agent needs** with the
>    integration, and keep it **read-only** (Read-content-only integration, leave `NOTION_WRITE` unset)
>    unless writes are genuinely required.

---

*See also:* [README.md](../README.md) (run / troubleshoot) · [docs/LEARNINGS.md](../docs/LEARNINGS.md)
(runtime gotchas, distilled) · [fixes/firecrawl.yaml](../fixes/firecrawl.yaml) (the one added
egress rule) · [nemoclaw.yaml](../nemoclaw.yaml) (sandbox declaration).

---

*↑ [[architecture/_index|Architecture index]] · part 6 of 6 · ← [[05-scheduling-architecture|Scheduling architecture]]*
