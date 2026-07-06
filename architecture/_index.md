# finn — Architecture

How finn is put together, where the trust boundaries are, and **how its security posture
differs from a stock NemoClaw sandbox**. Operational steps live in [README.md](../README.md);
the hard-won runtime gotchas live in [docs/LEARNINGS.md](../docs/LEARNINGS.md). This is the *why* and the
*security model*.

> [!summary] One-line answer
> On NemoClaw v0.0.67 finn is a **stock `nemoclaw onboard` sandbox** — no custom image —
> plus a few runtime tweaks. It keeps every load-bearing NemoClaw control: non-root
> execution, the `nemoclaw-start` gateway-auth machinery, the deny-by-default L7 egress
> proxy, and runtime-injected secrets. The only material posture change is **what the agent
> can read**: routing `web_fetch` through Firecrawl (search stays on the built-in brave)
> lets it read *any* public URL server-side instead of only policy-allowlisted hosts.
> `proxy.loopbackMode=gateway-only` does **not** loosen *external* egress and is now the
> **stock default** anyway (it is functionally required — without it the gateway's own
> loopback RPC is blocked by SSRF hardening; see
> [[03-security-analysis#proxy.loopbackMode = gateway-only|§4 · proxy.loopbackMode]]). Two
> optional **MCP add-ons** extend the agent with *tools it calls* (not new inbound channels):
> a personal Outlook/live.com **calendar** via a delegated, least-scope refresh token
> ([[04-add-on-security#6. Calendar add-on — Graph calendar via MCP|§4 item 6]]), and a
> **Notion** connector via an internal-integration token that sees only pages explicitly
> shared with it ([[04-add-on-security#7. Notion connector — via MCP|§4 item 7]]). Both are
> **read-only by default**, with writes behind an explicit opt-in.

> [!warning] 2026.6.10 update — the live finn now onboards from a custom image
> Since 2026-06-27 the live finn runs **OpenClaw 2026.6.10** via `nemoclaw onboard --from
> Dockerfile.finn-2026.6.10` (2026.6.x **un-bundles** firecrawl, so the fetch plugin is
> **installed at build time** from ClawHub — a small supply-chain delta vs. the stock-onboard
> posture described below, mitigated by the vendored, fail-closed NemoClaw patch in
> [`patches/`](../patches/README.md)). Everything else in this analysis — trust boundaries,
> egress path, add-on security — is unchanged by the image swap; the "bundled extension" rows
> describe the 2026.5.x stock path. See PROGRESS.md 2026-06-27.

---

## Read in order

| # | Part | What's in it |
|---|------|--------------|
| 1 | [[01-what-finn-is]] | What finn is — the component map, the host/sandbox diagram, and the search / fetch / add-on choices. |
| 2 | [[02-trust-and-egress]] | Trust boundaries & the egress path (§2) + every config delta vs. a stock sandbox (§3). |
| 3 | [[03-security-analysis]] | Security analysis (§4) — the loopback verdict, the real deltas (items 1–5), and the posture preserved from stock. |
| 4 | [[04-add-on-security]] | Security of the optional add-ons (§4 items 6–8) — calendar, Notion, and the radar cron loops. |
| 5 | [[05-scheduling-architecture]] | Proactive loops (§5) — the scheduling architecture: state-indirection + producer→consumer chaining. |
| 6 | [[06-net-posture]] | Net posture (§6) + hardening tips. |

> [!note] Section numbers are preserved across the split
> The original single-file `ARCHITECTURE.md` numbered its sections §1–§6 (with §4 carrying
> "items 1–8"). The split keeps those numbers, so existing "§4 item 6"-style citations in
> [PROGRESS.md](../PROGRESS.md) (and the maintainers' working notes) still resolve — §4 core lives in
> [[03-security-analysis]], its add-on items 6–8 in [[04-add-on-security]].

---

*See also:* [README.md](../README.md) (run / troubleshoot) · [docs/LEARNINGS.md](../docs/LEARNINGS.md)
(runtime gotchas, distilled) · [fixes/firecrawl.yaml](../fixes/firecrawl.yaml) (the one added
egress rule) · [nemoclaw.yaml](../nemoclaw.yaml) (sandbox declaration).
