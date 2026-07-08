# fixes/ — network-policy presets

Egress allowlists (OpenShell L7 policy presets) for finn's optional capabilities — the sandbox
is deny-by-default, so each add-on brings exactly the hosts it needs:

| Preset | Opens | Applied by |
|---|---|---|
| `firecrawl.yaml` | `api.firecrawl.dev:443` (server-side `web_fetch`) | `setup-finn.sh` |
| `exa.yaml` | `api.exa.ai:443` (optional alt search provider) | manual — see SETUP.md |
| `ms-calendar.yaml` | `graph.microsoft.com` + `login.microsoftonline.com` (adds DELETE vs the built-in `outlook` preset) | `setup-finn.sh` (calendar layer) |
| `notion.yaml` | `api.notion.com` GET/POST/PATCH (no DELETE exists in the API) | `setup-finn.sh` (notion layer) |

Apply by **register + activate by name** (copy into the blueprint presets dir, then
`nemoclaw finn policy-add <name> --yes`) — do **not** also use `policy-add --from-file`
for the same name; once registered they collide (see `docs/LEARNINGS.md` §6). Re-copy after
editing a preset, or the activated policy keeps the stale version.
