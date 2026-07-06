#!/usr/bin/env bash
set -euo pipefail

# setup-finn.sh  —  minimal one-shot setup for the "finn" research agent (NemoClaw >= v0.0.67)
#
# OPENCLAW 2026.6.x NOTE: on OpenClaw <= 2026.5.x firecrawl/exa shipped BUNDLED
# (enable-only). OpenClaw 2026.6.x UN-BUNDLED them — firecrawl is now an
# install-from-catalog plugin (step 3 installs the version-matched plugin, or
# falls back to baking it at build). Reaching 2026.6.10 also requires NemoClaw
# v0.0.68 + a 1-line chat-send patch tolerance (see PROGRESS.md 2026-06-26).
#
# WHAT CHANGED (the whole point of this rewrite). On nemoclaw v0.0.55 this took a
# custom production base image (finn-base:local) + a baked Firecrawl plugin + a
# ~9-step script. v0.0.67 absorbed almost all of that into the stock onboard:
#
#   * The stock base now ships `nemoclaw-start` — `nemoclaw onboard` alone gives a
#     working, authenticating gateway. NO custom Dockerfile, NO finn-base build.
#   * Web SEARCH works out of the box: provider=brave, BRAVE_API_KEY auto-injected
#     by onboard. Verified end-to-end (web_search returns real results), zero config.
#   * The old manual fixes are now defaults: proxy.loopbackMode=gateway-only,
#     gateway.mode=local, tools.toolSearch=false (NemoClaw applies the last one for
#     Nemotron via a model-specific manifest), and tools.codeMode is off by default.
#   * firecrawl + exa shipped as BUNDLED stock extensions on <= 2026.5.x (just
#     disabled). ON 2026.6.x THEY ARE UN-BUNDLED — firecrawl must be installed
#     (version-matched plugin, step 3); the rest (key + provider + policy +
#     /etc/hosts) is unchanged.
#
# So this script does only what's genuinely left:
#   1. ensure the sandbox exists (stock onboard — search works immediately)
#   2. Telegram channel (first-class `channels add`, token baked at rebuild)
#   3. full-page web FETCH via Firecrawl (Victor's choice; brave stays the SEARCH
#      provider): on 2026.6.x install the version-matched plugin (or bake at build),
#      then enable + key + policy + /etc/hosts. Skipped if FIRECRAWL_API_KEY unset.
#   4. health + functional verification
#
# Calendar (Outlook/live.com) is a separate optional add-on: ./runmod-finn-live.sh
#
# Usage:
#   export BRAVE_API_KEY="BSA..."         # search key — ensures key + egress (re-onboard-safe)
#   export FIRECRAWL_API_KEY="fc-..."     # optional — omit for search-only
#   export TELEGRAM_BOT_TOKEN="..."       # optional — omit to skip the bot
#   ./setup-finn.sh
#
# Env knobs: SANDBOX (default finn), SEARCH_PROVIDER (default brave),
#            SKIP_ONBOARD=1 (don't create the sandbox if missing).

SANDBOX="${SANDBOX:-finn}"
SEARCH_PROVIDER="${SEARCH_PROVIDER:-brave}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESETS_DIR="${PRESETS_DIR:-$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets}"

# --- 0. NemoClaw version preflight -------------------------------------------
# The golden path is built + verified against NemoClaw v0.0.68 EXACTLY
# (github.com/NVIDIA/NemoClaw/tags). Older versions lack OpenClaw-2026.6.x patch
# support (hard fail); newer ones are untested and may cover OpenClaw >= 2026.6.9
# upstream — in which case drop patches/nemoclaw-2026.6.x-chat-send-runid.patch
# (warn + continue). Bypass entirely with NEMOCLAW_VERSION_SKIP_CHECK=1.
NEMOCLAW_VERSION_EXPECTED="v0.0.68"
# true if $1 < $2 (dotted numeric versions, no leading v)
verlt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]; }
if [ -z "${NEMOCLAW_VERSION_SKIP_CHECK:-}" ]; then
  nv="$(nemoclaw --version 2>/dev/null | head -1 | grep -o 'v[0-9][0-9.]*' || true)"
  if [ -z "$nv" ]; then
    echo "ERROR: cannot determine the nemoclaw version ('nemoclaw --version' gave nothing); expected $NEMOCLAW_VERSION_EXPECTED." >&2
    echo "       Install/pin it from github.com/NVIDIA/NemoClaw/tags, or re-run with NEMOCLAW_VERSION_SKIP_CHECK=1." >&2
    exit 1
  elif [ "$nv" = "$NEMOCLAW_VERSION_EXPECTED" ]; then
    echo "==> NemoClaw:       $nv (the verified combination)"
  elif verlt "${nv#v}" "${NEMOCLAW_VERSION_EXPECTED#v}"; then
    echo "ERROR: nemoclaw $nv is OLDER than $NEMOCLAW_VERSION_EXPECTED — no OpenClaw 2026.6.x patch support; aborting." >&2
    echo "       Upgrade (github.com/NVIDIA/NemoClaw/tags), or force with NEMOCLAW_VERSION_SKIP_CHECK=1." >&2
    exit 1
  else
    echo "==> NemoClaw:       $nv — NEWER than the verified $NEMOCLAW_VERSION_EXPECTED; untested, continuing." >&2
    echo "    If upstream now patches OpenClaw >= 2026.6.9, drop patches/nemoclaw-2026.6.x-chat-send-runid.patch." >&2
  fi
fi

echo "==> Sandbox:        $SANDBOX"
echo "==> Search:         $SEARCH_PROVIDER ($([ -n "${BRAVE_API_KEY:-}" ] && echo 'key + egress ensured below (step 2b)' || echo 'relying on onboard key injection — may be unkeyed after a re-onboard'))"
echo "==> Fetch:          $([ -n "${FIRECRAWL_API_KEY:-}" ] && echo 'firecrawl (bundled <=2026.5.x / installed plugin on 2026.6.x)' || echo 'search-only (set FIRECRAWL_API_KEY to add full-page fetch)')"

# Run a command inside the sandbox as the sandbox user with HOME set.
oc() { nemoclaw "$SANDBOX" exec -- bash -c "HOME=/sandbox $*" 2>/dev/null; }

# --- 1. Ensure the sandbox exists (stock onboard) ---------------------------
# A plain onboard gives a working gateway + brave web search with nothing custom.
if nemoclaw "$SANDBOX" status >/dev/null 2>&1; then
  echo "==> $SANDBOX already exists — skipping onboard (idempotent)."
elif [ "${SKIP_ONBOARD:-0}" = 1 ]; then
  echo "ERROR: $SANDBOX does not exist and SKIP_ONBOARD=1. Run 'nemoclaw onboard --name $SANDBOX' first." >&2
  exit 1
else
  # Clear a lingering custom `brave` provider PROFILE so onboard's provider-profile
  # import doesn't collide ("custom provider profile 'brave' already exists →
  # provider profile import failed"). `import` has no --force, so a re-onboard after
  # a prior import always trips on it. This deletes only the custom TEMPLATE; any
  # existing provider INSTANCE (e.g. finn-brave-search, which holds BRAVE_API_KEY)
  # is a separate object and is unaffected. Harmless if no such profile exists.
  openshell provider profile delete brave >/dev/null 2>&1 || true
  echo "==> Onboarding $SANDBOX (stock image — gateway + brave search, no custom Dockerfile) ..."
  nemoclaw onboard --name "$SANDBOX"
fi

# --- 2. Telegram channel (first-class; token baked at rebuild) --------------
# v0.0.67 replaces the old in-sandbox `openclaw config set channels.telegram.*`
# hack: `nemoclaw <name> channels add telegram` stores the token host-side and
# rebuilds so it's baked into the image (survives restarts). It is INTERACTIVE —
# it prompts for the bot token and confirms the rebuild — so run this script from
# a terminal for a fresh sandbox. Idempotent: skipped if telegram is already on.
if [ "$(oc 'openclaw config get channels.telegram.enabled' | tail -1)" = "true" ]; then
  echo "==> Telegram already enabled on $SANDBOX — leaving as-is."
elif [ -t 0 ]; then
  echo "==> Adding Telegram channel (interactive: prompts for token, then REBUILDS) ..."
  nemoclaw "$SANDBOX" channels add telegram \
    || echo "    NOTE: 'channels add telegram' did not complete — re-run it by hand."
  echo "    After restart: DM the bot, then  nemoclaw $SANDBOX exec -- openclaw pairing list telegram  /  approve telegram <CODE>"
else
  echo "==> Skipping Telegram: not a TTY. Run by hand:  nemoclaw $SANDBOX channels add telegram"
fi

# --- 2b. Brave web SEARCH: ensure the key + egress (idempotent) -------------
# Step 1 calls brave "auto-injected by onboard" — but that only holds for a FRESH
# onboard with BRAVE_API_KEY in the env. A re-onboard / rebuild (or an onboard run
# WITHOUT the key) leaves brave with an OpenShell PLACEHOLDER apiKey
# (__OPENCLAW_REDACTED__) AND the `brave` egress preset INACTIVE → web_search fails
# with "fetch failed" (root cause confirmed 2026-06-28: a bare re-onboard wiped the
# key + dropped the preset; search only came back after the two fixes below). So make
# both explicit and idempotent here — cheap to re-run, closes the gap.
if [ -n "${BRAVE_API_KEY:-}" ]; then
  # 2b-i. Open egress to the Brave Search API. `brave` is a BUILT-IN preset, so add
  #       it BY NAME (no yaml to copy). Applies live — no rebuild (policy versions bump).
  echo "==> Activating brave search egress (api.search.brave.com) ..."
  nemoclaw "$SANDBOX" policy-add brave --yes \
    || echo "    (policy-add brave non-zero — may already be applied; check: nemoclaw $SANDBOX policy-list)"

  # 2b-ii. Inject the key into plugin config (generic provider creds are NOT
  #        auto-injected; the plugin reads config.webSearch.apiKey — env is fallback).
  #        openclaw stores it redacted (reads back __OPENCLAW_REDACTED__, so a `config
  #        get` check is useless — verify via the raw json or a live web_search). Kept
  #        out of the repo/image; re-applied here every run (a rebuild wipes it).
  echo "==> Injecting Brave search key + pinning search=brave ..."
  oc "openclaw config set tools.web.search.provider brave" >/dev/null || true
  oc "openclaw config set plugins.entries.brave.config.webSearch.apiKey '$BRAVE_API_KEY'" >/dev/null \
    && echo "    Set webSearch.apiKey (brave)." \
    || echo "    WARNING: failed to set brave apiKey — set it manually."
else
  echo "==> BRAVE_API_KEY not set — leaving brave to onboard's injection (web_search may be"
  echo "    unkeyed after a re-onboard; export BRAVE_API_KEY and re-run to guarantee it)."
fi

# --- 3. Full-page web FETCH via the Firecrawl plugin ------------------------
# SEARCH stays on brave (OOTB). We only add FETCH so the agent can read whole
# pages (not just brave snippets) without allow-listing every site — Firecrawl
# scrapes server-side through its single endpoint (api.firecrawl.dev).
#
# On OpenClaw <= 2026.5.x firecrawl was BUNDLED (just enable it). On 2026.6.x it
# is UN-BUNDLED, so step 3b installs the version-matched plugin (or you bake it at
# build). Then: enable + point fetch at it + supply the key + open egress +
# /etc/hosts. (tools.codeMode is off by default, so the old isolated-child
# EAI_AGAIN problem doesn't apply — no need to disable it.)
if [ -n "${FIRECRAWL_API_KEY:-}" ]; then
  # 3a. Register + activate the firecrawl egress policy (api.firecrawl.dev only).
  #     Copy into the blueprint, then activate BY NAME (--from-file collides once
  #     registered — see docs/LEARNINGS.md �6).
  if [ -d "$PRESETS_DIR" ]; then
    cp "$HERE/fixes/firecrawl.yaml" "$PRESETS_DIR/"
    echo "==> Registered fixes/firecrawl.yaml in the blueprint."
  else
    echo "WARNING: presets dir not found ($PRESETS_DIR) — set PRESETS_DIR; trying policy-add anyway." >&2
  fi
  echo "==> Applying firecrawl egress policy ..."
  nemoclaw "$SANDBOX" policy-add firecrawl --yes \
    || echo "    (policy-add non-zero — may already be applied; check: nemoclaw $SANDBOX policy-list)"

  # 3b. Ensure the firecrawl PLUGIN exists, then enable it + point FETCH at it.
  #     VERSION SPLIT (verified 2026-06-26): OpenClaw <= 2026.5.x ships firecrawl
  #     as a BUNDLED extension (just enable it). OpenClaw 2026.6.x UN-BUNDLED it
  #     (now an install-from-catalog plugin, like brave) — so on 2026.6.x we must
  #     `openclaw plugins install` the VERSION-MATCHED plugin first (npm: spec, same
  #     as the Dockerfile's brave install; `clawhub:` was an old-OpenClaw artifact).
  #     A runtime install needs npm-registry egress, which the sandbox blocks by
  #     default — so the ROBUST path is to BAKE it into the onboard Dockerfile
  #     (nemoclaw onboard --from); this block falls back to that instruction.
  OCV="$(oc 'openclaw --version' | awk '{print $2}' | tr -d '\r')"
  if [ -n "$OCV" ] && [ "$(printf '%s\n%s\n' "2026.6.0" "$OCV" | sort -V | head -n1)" = "2026.6.0" ]; then
    if oc 'openclaw plugins list' | grep -qiE 'firecrawl'; then
      echo "==> firecrawl plugin already installed/baked (OpenClaw $OCV) — skipping install."
    else
      echo "==> OpenClaw $OCV un-bundles firecrawl — installing @openclaw/firecrawl-plugin@$OCV ..."
      oc "openclaw plugins install 'npm:@openclaw/firecrawl-plugin@$OCV' --pin" >/dev/null 2>&1 \
        && echo "    Installed @openclaw/firecrawl-plugin@$OCV. (A freshly-installed plugin needs a" \
        && echo "    FULL gateway restart to load — 'recover' alone hot-reloads only; if web_fetch still" \
        && echo "    reports no provider, do the runmod-style restart: kill the openclaw child of nemoclaw-start.)" \
        || { echo "    WARNING: runtime plugin install failed (sandbox likely blocks npm-registry egress)."; \
             echo "             ROBUST FIX — bake it into your onboard Dockerfile (nemoclaw onboard --from):"; \
             echo "               RUN HOME=/sandbox openclaw plugins install 'npm:@openclaw/firecrawl-plugin@$OCV' --pin"; \
             echo "             (Build-time egress is direct, so the install succeeds and the agent's runtime"; \
             echo "              egress stays locked to api.firecrawl.dev — same model as the baked brave plugin.)"; }
    fi
  else
    echo "==> OpenClaw ${OCV:-<=2026.5.x} bundles firecrawl — enabling the bundled extension."
  fi

  # 3c. Enable the plugin + set FETCH provider (leave SEARCH on brave) and inject
  #     the key into the plugin config (generic provider creds are NOT auto-injected;
  #     the plugin reads config.webFetch.apiKey — env is fallback). openclaw stores
  #     it redacted (reads back __OPENCLAW_REDACTED__); kept out of the repo/image and
  #     re-applied here on every run. Works whether firecrawl was bundled or installed.
  echo "==> Pointing web_fetch at firecrawl + injecting key ..."
  oc "openclaw config set plugins.entries.firecrawl.enabled true" >/dev/null || true
  oc "openclaw config set tools.web.fetch.provider firecrawl" >/dev/null || true
  oc "openclaw config set plugins.entries.firecrawl.config.webFetch.baseUrl https://api.firecrawl.dev" >/dev/null || true
  oc "openclaw config set tools.web.search.provider $SEARCH_PROVIDER" >/dev/null || true   # keep search = brave
  oc "openclaw config set plugins.entries.firecrawl.config.webFetch.apiKey '$FIRECRAWL_API_KEY'" >/dev/null \
    && echo "    Set web_fetch=firecrawl + webFetch.apiKey (search stays $SEARCH_PROVIDER)." \
    || echo "    WARNING: failed to set firecrawl apiKey — set it manually (see README)."

  # 3d. /etc/hosts: api.firecrawl.dev -> a public IP. The firecrawl plugin runs an
  #     SSRF dns.lookup precheck via the LOCAL resolver, which can't resolve any
  #     external host here (real egress goes through the proxy). Any public IP makes
  #     the "not private" check pass; the actual request still goes via the proxy.
  #     A full rebuild regenerates /etc/hosts, so re-add after onboard/channels-add.
  echo "==> Adding /etc/hosts alias for api.firecrawl.dev (SSRF-precheck fix) ..."
  FC_IP="$( { dig +short api.firecrawl.dev A 2>/dev/null; } | grep -E '^[0-9]+\.' | head -1 )"
  FC_IP="${FC_IP:-35.245.250.27}"
  CID="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
  if [ -n "$CID" ]; then
    docker exec -u 0 "$CID" sh -c "grep -q 'api.firecrawl.dev' /etc/hosts || echo '$FC_IP api.firecrawl.dev' >> /etc/hosts" \
      && echo "    Added '$FC_IP api.firecrawl.dev'." \
      || echo "    WARNING: failed to add /etc/hosts alias."
  else
    echo "    WARNING: sandbox container not found; add manually after it's up."
  fi
else
  echo "==> Skipping Firecrawl fetch layer (FIRECRAWL_API_KEY not set) — search-only."
fi

# --- 4. Restart + verify ----------------------------------------------------
echo "==> Restarting the gateway to apply runtime config ..."
nemoclaw "$SANDBOX" recover >/dev/null 2>&1 || true

echo
echo "==> Config snapshot:"
printf "    search provider : %s\n" "$(oc 'openclaw config get tools.web.search.provider' | tail -1)"
printf "    fetch provider  : %s\n" "$(oc 'openclaw config get tools.web.fetch.provider' | tail -1)"
printf "    telegram        : %s\n" "$(oc 'openclaw config get channels.telegram.enabled' | tail -1)"
printf "    codeMode        : %s (expect off/unset)\n" "$(oc 'openclaw config get tools.codeMode.enabled' | tail -1)"
printf "    proxy loopback  : %s (expect gateway-only)\n" "$(oc 'openclaw config get proxy.loopbackMode' | tail -1)"
echo
echo "==> nemoclaw $SANDBOX policy-list:"
nemoclaw "$SANDBOX" policy-list 2>/dev/null | grep -v -E 'UNDICI|trace-warn' | head -20 || true

cat <<EOF

==> Functional self-test (search runs through brave OOTB):
    nemoclaw $SANDBOX agent --agent main -m "use web_search to find nvidia.com and report the URL"
$([ -n "${FIRECRAWL_API_KEY:-}" ] && printf '    nemoclaw %s agent --agent main -m "use web_fetch to read https://blogs.nvidia.com and give the headline"\n' "$SANDBOX")

✅ Done. Search works out of the box; $([ -n "${FIRECRAWL_API_KEY:-}" ] && echo 'full-page fetch via Firecrawl is wired' || echo 'set FIRECRAWL_API_KEY and re-run to add full-page fetch').
   Telegram: DM the bot, then approve pairing (see above). Calendar: ./runmod-finn-live.sh
EOF
