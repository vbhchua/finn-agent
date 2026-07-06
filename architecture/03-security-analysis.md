*↑ [[architecture/_index|Architecture index]] · part 3 of 6 · ← [[02-trust-and-egress|Trust boundaries & egress]] · next: [[04-add-on-security|Add-on security]] →*

# 4. Security analysis — core posture

The core security posture of the base sandbox. The optional add-ons (this same §4's
**items 6–8** — calendar, Notion, radar cron loops) are analysed in [[04-add-on-security]].

## proxy.loopbackMode = gateway-only

**Verdict: no effect on *external* egress security; it is FUNCTIONALLY REQUIRED in this
topology — and on v0.0.67 it is the STOCK DEFAULT, so finn no longer sets it.** (It is kept
in this section because it is load-bearing and the reasoning is worth recording — a live
denial flood on the older `"proxy"` default proved it is not inert.)

- `loopbackMode` governs only how **loopback** traffic (127.0.0.1 → the gateway's own RPC)
  is handled. Default `"proxy"` routes even loopback RPC through the SSRF proxy / OPA egress
  layer; `"gateway-only"` makes loopback RPC bypass that interception and reach the gateway
  directly.
- **What forced the correction (2026-06-22):** with the stock `"proxy"` mode, the embedded
  agent's loopback connection to the gateway is intercepted by OpenShell's OPA layer and
  **denied unconditionally**:
  ```
  NET:OPEN DENIED node -> 127.0.0.1:18789 [policy:- engine:opa]
  Skipped proposal for always-blocked destination (SSRF hardening — loopback/link-local/unspecified)
  ```
  This repeats ~1×/sec — a denial flood + constant policy-analysis churn. You **cannot** fix
  it by allowlisting `127.0.0.1` in a network policy: SSRF hardening blocks loopback/link-local
  *unconditionally*, regardless of policy. The only fix is `loopbackMode=gateway-only`, which
  takes that loopback RPC off the OPA-intercepted path. (The exact mechanism is still an open
  question: openclaw's CLI doesn't recognize `proxy.*`, so either OpenShell reads
  `proxy.loopbackMode` from `openclaw.json` to decide whether to intercept loopback, or
  gateway-only changes openclaw's loopback transport so no TCP `NET:OPEN` is emitted. Either
  way the setting is observably load-bearing.)
- **Security framing is still favorable:** it does **not** affect external egress. Traffic to
  `api.exa.ai`, `api.firecrawl.dev`, `api.telegram.org`, `inference.local`, and everything
  else still goes through the L7 proxy and is still policy-governed. The SSRF/egress firewall
  for *external and internal-network* destinations is unchanged; the real SSRF targets (cloud
  metadata `169.254.169.254`, RFC1918 internal services) are **not loopback** and stay on the
  policed path. What `gateway-only` exempts is solely the gateway's own 127.0.0.1 RPC — which
  has to work for the agent to function at all.
- **Do NOT override it to `"proxy"`** on this host-process topology — that breaks the gateway
  with the denial flood above. On v0.0.67 `gateway-only` is the shipped default, so this is
  now a "don't undo a good default," not a manual step. (Earlier base images defaulted to
  `"proxy"`, which suits the normal Linux cluster topology but not finn's macOS host-process
  layout — hence the original need to set it by hand.)

## The real deltas (more significant than loopbackMode)

> [!warning] 1. Firecrawl `web_fetch` removes the host allowlist on *reads*
> Stock `web_fetch` is forced through the trusted env proxy, so the agent can fetch **only
> policy-allowlisted hosts**. With Firecrawl, the agent calls `api.firecrawl.dev` (allowed)
> and **Firecrawl fetches the target URL server-side** — so the L7 host policy no longer
> constrains *what content the agent can read*; any public URL is reachable. This is
> **intentional** (the whole point: no per-domain allowlist) and is the single biggest
> posture change.
> - **Mitigated:** Firecrawl runs in the cloud, so it can't reach the *sandbox's* internal
>   network — SSRF-to-internal via the fetch tool is not introduced.
> - **Residual:** (a) a prompt-injection surface — the agent reads arbitrary, possibly
>   attacker-controlled, web content; (b) a data-exfil path — an injected instruction could
>   make the agent scrape an attacker URL with secrets in the query string. Bounded by the
>   research-only task scope and the fact that the agent holds few secrets.

> [!note] 2. `tools.codeMode` is off by default — not a finn delta anymore
> Code mode would run the model's tool calls in an **isolated Node child** (empty env,
> restricted resolver); with it off, `web_search`/`web_fetch` run **in the gateway process**.
> On v0.0.67 code mode is **off by default** (stock and finn alike), so this is a property of
> the platform + Nemotron, not a change finn makes — the old build no longer has to disable it.
> (Nemotron also can't reliably drive the code-mode API, which is why the default suits it.)
> Lower tool-execution isolation than code-mode-on, but the blast radius is still bounded by
> the L7 egress policy. If you switch to a model strong at code mode (e.g. Codex), you can
> turn it on.

> [!note] 3. `/etc/hosts` pin for `api.firecrawl.dev` — low impact
> A **public** IP is pinned so the Firecrawl plugin's SSRF pre-check (`dns.lookup`, which the
> sandbox's local resolver can't answer) passes "not private." It satisfies a defense-in-depth
> check cosmetically (any public IP works, even a stale one) — but the **actual** request
> still goes through the proxy, which does its own resolution + policy enforcement. It does
> not open a direct egress hole.

> [!note] 4. Supply chain — back to stock (improved vs v0.0.55)
> The old build bumped OpenClaw to `@latest` and installed `clawhub:@openclaw/firecrawl-plugin`
> into the trusted gateway process — extra un-pinned third-party code. On v0.0.67 that's gone:
> **Firecrawl (and Exa) ship as bundled stock extensions at the pinned OpenClaw version**, so
> finn enables existing first-party code instead of fetching new code. No version bump, no
> `clawhub` install — the supply-chain surface is the same as a stock sandbox.

> [!note] 5. Minor — secret on the command line
> `setup-finn.sh` passes `FIRECRAWL_API_KEY` inside `bash -c "… '$KEY' …"`, so it appears
> in the process arg list (`ps`/`/proc`) for an instant and could reach shell history. Output
> is redirected and OpenClaw stores the key redacted, but prefer env/stdin if hardening.

> [!info] Items 6–8 — the optional add-ons
> The remaining §4 items cover the optional add-ons (calendar, Notion, radar cron loops) and
> live in [[04-add-on-security]].

## Posture that is *preserved* (unchanged from stock)

- **Non-root execution** as uid 998 — the stock image runs the gateway as `sandbox`;
  runtime config edits stay sandbox-owned (mutable mode). (On v0.0.55 this was the #1 way a
  custom build silently broke — root-run build steps leave root-owned config + a locked `/tmp`;
  with a stock image it's free.)
- **Gateway auth** — `nemoclaw-start` ships in the stock base; the supervisor injects
  `OPENCLAW_GATEWAY_TOKEN`. The old community-base attempt died exactly because it lacked this.
- **Egress proxy on** — `proxy.enabled=true`; deny-by-default L7 policy intact.
- **Runtime secret injection** — no API keys in image layers.
- **Telegram `dmPolicy=pairing`** — inbound control requires manual pairing approval (codes
  expire in 1h); one bot token may be polled by only one sandbox.

---

*↑ [[architecture/_index|Architecture index]] · part 3 of 6 · ← [[02-trust-and-egress|Trust boundaries & egress]] · next: [[04-add-on-security|Add-on security]] →*
