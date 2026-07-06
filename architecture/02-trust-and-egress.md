*↑ [[architecture/_index|Architecture index]] · part 2 of 6 · ← [[01-what-finn-is|What finn is]] · next: [[03-security-analysis|Security analysis]] →*

# Trust boundaries, egress & config deltas

## 2. Trust boundaries & the egress path

The **OpenShell L7 proxy is the single egress authority.** This is the design intent stated
in NemoClaw's own config generator (`scripts/generate-openclaw-config.py`):

> *"OpenShell's L7 policy remains the egress authority: without an approved host:port, the
> proxy denies the request."*

Every outbound request from inside the sandbox is routed to that proxy (`proxy.enabled=true`,
`proxyUrl=http://10.200.0.1:3128`), which allows a destination only if a network policy
names it. Search runs on the stock **brave** policy (`api.search.brave.com`); finn adds
exactly one host beyond the default set: **`api.firecrawl.dev:443`** (`fixes/firecrawl.yaml`)
for `web_fetch`. Direct egress to any other site stays denied — you'll see
`NET:OPEN DENIED … <site>` in the logs, immediately followed by a Firecrawl scrape of that
same URL. **That is the policy working as intended**, not a leak.

Secrets never enter the image. They're injected at runtime: messaging-channel tokens baked at
`channels add` rebuild time, and the Firecrawl key written into the sandbox's mutable
`openclaw.json` by `setup-finn.sh` (stored redacted at rest).

---

## 3. Config deltas vs. a stock NemoClaw sandbox

What `setup-finn.sh` changes relative to a vanilla `nemoclaw onboard`. On v0.0.67 the list
is **much shorter than on v0.0.55** — most former deltas (codeMode, toolSearch, loopbackMode,
the OpenClaw upgrade) are now the **stock defaults**, so they're no longer changes finn makes.

| Setting | Stock NemoClaw | finn | Security-relevant? |
|---|---|---|---|
| Runs as | uid 998 `sandbox`, non-root | **same** (stock image) | ✅ preserved |
| Entrypoint | `nemoclaw-start` (gateway auth token) | **same** (stock base) | ✅ preserved |
| `proxy.enabled` | `true` | **same** (`true`) | ✅ preserved |
| Egress model | deny-by-default L7 proxy | **same** + `api.firecrawl.dev` allowed | ⚠️ see §4 |
| `web_fetch` | keyless, `useTrustedEnvProxy` → only **policy-allowed hosts** | via **Firecrawl** → **any public URL** server-side | ⚠️ **the one real delta** |
| `web_search` | `brave` (BRAVE_API_KEY, auto-injected) | **same** (`brave`) | neutral |
| `tools.codeMode.enabled` | off by default | **same** (unchanged) | ✅ no longer a delta |
| `tools.toolSearch` | `false` for Nemotron (model manifest) | **same** | ✅ no longer a delta |
| `proxy.loopbackMode` | `gateway-only` (default) | **same** | ✅ no longer a delta (still functionally required — §4) |
| `/etc/hosts` | resolver-only | + pinned **public IP** for `api.firecrawl.dev` | ❎ low — see §4 |
| Secrets | runtime (channel tokens baked at rebuild) | **same** + Firecrawl key in mutable config | ✅ preserved |
| OpenClaw version | pinned (2026.5.27) | **same** — firecrawl is a *bundled* extension, no upgrade/3rd-party install | ✅ no longer a supply-chain delta |
| MCP servers (add-on) | none | calendar: `mcp.servers.ms-calendar`; Notion: `mcp.servers.notion` — both **local stdio, our zero-dep code** | ⚠️ see §4 items 6–7 *(add-on only)* |
| Egress hosts (add-on) | — | calendar: + `graph.microsoft.com` (GET/POST/PATCH/DELETE) + `login.microsoftonline.com`; Notion: + `api.notion.com` (GET/POST/PATCH) | ⚠️ read+write surface (writes opt-in) — §4 items 6–7 |
| Add-on secret | — | calendar: delegated **refresh token**; Notion: **integration token** — each in a `0600` sandbox-only file (`/sandbox/.config/*.env`), least scope for the mode | ✅ runtime-injected, never in image/repo/`openclaw.json` |

The net of v0.0.67: finn now differs from stock in **two** load-bearing ways —
`web_fetch` reaches any public URL via Firecrawl (the deliberate capability), and the
optional **MCP add-ons** (calendar + Notion, each read-only by default). Everything else that
used to be a delta became a default.

> [!note] Where the "§4" cells point
> The ⚠️ rows above are analysed in the security sections: the core posture (loopback, the
> Firecrawl read delta, the preserved controls) in [[03-security-analysis]]; the add-on items
> 6–8 in [[04-add-on-security]].

---

*↑ [[architecture/_index|Architecture index]] · part 2 of 6 · ← [[01-what-finn-is|What finn is]] · next: [[03-security-analysis|Security analysis]] →*
