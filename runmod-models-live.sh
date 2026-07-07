#!/usr/bin/env bash
set -euo pipefail

# runmod-models-live.sh
#
# "runmod" = a RUNTIME MODIFICATION of a LIVE, already-running finn sandbox
# (vs setup-finn.sh, which onboards the sandbox and wires search/fetch/Telegram).
# It mutates the running gateway's config + policy in place and does NOT rebuild
# the image — so it must be re-applied after a full rebuild/onboard.
# Standalone optional add-on: run it AFTER ./setup-finn.sh; not invoked by it.
#
# Points finn's model stack at KIMI K2.6 (Moonshot AI) with an optional
# OPENROUTER direct fallback route:
#
#   PRIMARY   inference/<KIMI_MODEL>  — still the managed inference.local route;
#             the HOST gateway's 'compatible-endpoint' provider forwards to
#             https://api.moonshot.ai/v1 with MOONSHOT_API_KEY. The sandbox
#             config keeps apiKey="unused" (the gateway injects the real key),
#             so NemoClaw's compatible-endpoint onboarding smoke check passes
#             against exactly this shape.
#   FALLBACK  <OPENROUTER_MODEL> (default openrouter/moonshotai/kimi-k2.6) —
#             OpenClaw's BUILT-IN openrouter provider, activated by putting
#             OPENROUTER_API_KEY into the config env. This is a DIRECT call
#             from the gateway netns to openrouter.ai, so it needs the
#             fixes/openrouter.yaml egress preset (applied below).
#
# PREREQUISITES:
#   * The host gateway 'compatible-endpoint' provider is registered and points
#     at https://api.moonshot.ai/v1 (done once at `nemoclaw onboard` when you
#     pick "Other OpenAI-compatible endpoint" and paste MOONSHOT_API_KEY).
#   * Optional: export OPENROUTER_API_KEY (sk-or-...) to enable the fallback.
#
#     set -a; . ./.env; set +a
#     ./runmod-models-live.sh
#
# Running WITHOUT OPENROUTER_API_KEY still switches the primary to Kimi and
# pre-applies the openrouter egress policy; the fallback route stays
# unconfigured until you re-run with the key set.

SANDBOX="${SANDBOX:-finn}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESET="openrouter"

# Presets dir: `npm root -g` is brittle under nvm (the active node can differ
# from the one nemoclaw was installed/linked with), so fall back to following
# the nemoclaw launcher to its real bin/nemoclaw.js and hopping to the blueprint.
resolve_presets_dir() {
  d="$(npm root -g 2>/dev/null)/nemoclaw/nemoclaw-blueprint/policies/presets"
  [ -d "$d" ] && { echo "$d"; return; }
  launcher="$(command -v nemoclaw 2>/dev/null || true)"
  [ -n "$launcher" ] || { echo ""; return; }
  real="$(readlink -f "$launcher" 2>/dev/null || true)"
  case "$real" in
    *nemoclaw.js) : ;;
    *) execpath="$(grep -oE '"[^"]*/bin/nemoclaw"' "$real" 2>/dev/null | tr -d '"' | head -1)"
       [ -n "$execpath" ] && real="$(readlink -f "$execpath" 2>/dev/null || true)" ;;
  esac
  d="$(dirname "$real")/../nemoclaw-blueprint/policies/presets"
  [ -d "$d" ] && (cd "$d" && pwd) || echo ""
}
PRESETS_DIR="${PRESETS_DIR:-$(resolve_presets_dir)}"

KIMI_MODEL="${KIMI_MODEL:-kimi-k2.6}"
KIMI_CONTEXT_WINDOW="${KIMI_CONTEXT_WINDOW:-262144}"
KIMI_MAX_TOKENS="${KIMI_MAX_TOKENS:-8192}"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-openrouter/moonshotai/kimi-k2.6}"

echo "==> Sandbox:     $SANDBOX"
echo "==> Primary:     inference/$KIMI_MODEL (via gateway compatible-endpoint -> api.moonshot.ai)"
echo "==> Fallback:    $OPENROUTER_MODEL $([ -n "${OPENROUTER_API_KEY:-}" ] && echo '(key set — will be configured)' || echo '(OPENROUTER_API_KEY not set — skipped)')"
echo "==> Presets dir: $PRESETS_DIR"

CONTAINER="$(docker ps --filter name=openshell-"$SANDBOX" --format '{{.Names}}' | head -1)"
[ -n "$CONTAINER" ] || { echo "ERROR: running sandbox container not found (is $SANDBOX up? run ./setup-finn.sh first)." >&2; exit 1; }
echo "==> Container:   $CONTAINER"

# --- 1. Register + activate the openrouter egress policy --------------------
# openrouter.ai only. Copy into the blueprint, then activate BY NAME (--from-file
# would collide once registered — see docs/LEARNINGS.md §6). Host-side: survives
# rebuilds; applying it without the key is harmless (least-noise on re-runs).
if [ -d "$PRESETS_DIR" ]; then
  cp "$HERE/fixes/$PRESET.yaml" "$PRESETS_DIR/"
  echo "==> Copied fixes/$PRESET.yaml into the blueprint."
else
  echo "WARNING: presets dir not found ($PRESETS_DIR); set PRESETS_DIR. Trying policy-add anyway." >&2
fi
echo "==> Applying '$PRESET' network policy ..."
nemoclaw "$SANDBOX" policy-add "$PRESET" --yes \
  || echo "    (policy-add non-zero — may already be applied; check: nemoclaw $SANDBOX policy-list)"

# --- 2. Rewrite the model config in openclaw.json (idempotent) --------------
echo "==> Updating /sandbox/.openclaw/openclaw.json (backup: openclaw.json.pre-models) ..."
docker exec -i -u 998 -e HOME=/sandbox \
  -e KIMI_MODEL="$KIMI_MODEL" -e KIMI_CTX="$KIMI_CONTEXT_WINDOW" -e KIMI_MAX="$KIMI_MAX_TOKENS" \
  -e OR_MODEL="$OPENROUTER_MODEL" -e OR_KEY="${OPENROUTER_API_KEY:-}" \
  "$CONTAINER" python3 - <<'PY'
import json, os, shutil

p = "/sandbox/.openclaw/openclaw.json"
kimi = os.environ["KIMI_MODEL"]
or_model = os.environ["OR_MODEL"]
or_key = os.environ.get("OR_KEY", "")

shutil.copy(p, p + ".pre-models")
cfg = json.load(open(p))

# Primary: Kimi through the managed inference.local route (gateway holds the key).
defaults = cfg["agents"]["defaults"]
defaults.setdefault("model", {})["primary"] = f"inference/{kimi}"

models = cfg["models"]["providers"]["inference"].setdefault("models", [])
if not any(m.get("id") == kimi for m in models):
    models.append({
        "id": kimi,
        "name": f"inference/{kimi}",
        "reasoning": False,
        "input": ["text"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": int(os.environ["KIMI_CTX"]),
        "maxTokens": int(os.environ["KIMI_MAX"]),
    })

# Fallback: OpenClaw's built-in openrouter provider — only when the key exists.
# (env key + fallbacks + an agents.defaults.models entry, per OpenRouter's
# OpenClaw cookbook; no models.providers block needed.)
if or_key:
    cfg.setdefault("env", {})["OPENROUTER_API_KEY"] = or_key
    fallbacks = defaults["model"].setdefault("fallbacks", [])
    if or_model not in fallbacks:
        fallbacks.append(or_model)
    agent_models = defaults.setdefault("models", {})
    agent_models.setdefault(f"inference/{kimi}", {})
    agent_models.setdefault(or_model, {})
    print(f"    primary=inference/{kimi}  fallbacks={fallbacks}")
else:
    print(f"    primary=inference/{kimi}  (no OpenRouter fallback — key not set)")

json.dump(cfg, open(p, "w"), indent=2)
PY

# --- 3. Apply via a FULL gateway restart -------------------------------------
# Model/provider config is read at gateway start; a hot-reload is not reliable on
# this OpenClaw (same mechanics as the MCP runtime — docs/LEARNINGS.md §2). Never
# `docker restart` (§5): TERM the worker and let nemoclaw-start relaunch it.
echo "==> Restarting the gateway to load the new model config ..."
GLOG="/tmp/gateway.log"
before="$(docker exec -u 0 "$CONTAINER" sh -c "wc -l < $GLOG 2>/dev/null" | tr -d '[:space:]')"
GWPID="$(docker exec -u 0 "$CONTAINER" sh -c '
  for p in $(pgrep -x openclaw 2>/dev/null); do
    pp=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
    tr "\0" " " < /proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }
  done' 2>/dev/null | head -1)"
if [ -n "$GWPID" ]; then
  docker exec -u 0 "$CONTAINER" sh -c "kill -TERM $GWPID" \
    && echo "    Sent TERM to the gateway worker (pid $GWPID); supervisor relaunching a fresh gateway ..."
else
  echo "    NOTE: gateway worker not found by name+parent; falling back to nemoclaw recover."
  nemoclaw "$SANDBOX" recover >/dev/null 2>&1 || true
fi

echo "==> Verifying the gateway came back up (log: 'http server listening' / 'ready') ..."
ok=""
for _ in 1 2 3 4 5 6 7 8; do
  if docker exec -u 0 "$CONTAINER" sh -c "tail -n +$(( ${before:-0} + 1 )) $GLOG 2>/dev/null" \
       | grep -qiE "http server listening|\[gateway\] ready"; then ok=1; break; fi
  sleep 5
done
if [ -n "$ok" ]; then
  echo "    Gateway restarted cleanly (fresh 'listening'/'ready' in $GLOG)."
else
  echo "    NOTE: no fresh restart line yet. Re-check the log, or restart by hand:"
  echo "      docker exec -u 0 $CONTAINER sh -c 'pkill -TERM -f \"gateway run\"'"
fi

# --- 4. Verify ---------------------------------------------------------------
# Both probes run from the GATEWAY's netns (nsenter + proxy env + MITM CA) —
# main-netns probes false-negative here (docs/LEARNINGS.md §1/§3).
echo "==> Verifying ..."
NEWPID="$(docker exec -u 0 "$CONTAINER" sh -c '
  for p in $(pgrep -x openclaw 2>/dev/null); do
    pp=$(awk "{print \$4}" /proc/$p/stat 2>/dev/null)
    tr "\0" " " < /proc/$pp/cmdline 2>/dev/null | grep -q nemoclaw-start && { echo $p; break; }
  done' 2>/dev/null | head -1)"
if [ -n "$NEWPID" ]; then
  echo "    --- inference.local -> $KIMI_MODEL (PONG probe): ---"
  docker exec -u 0 -e M="$KIMI_MODEL" "$CONTAINER" sh -c '
    nsenter -t '"$NEWPID"' -n env https_proxy=http://10.200.0.1:3128 \
      CURL_CA_BUNDLE=/etc/openshell-tls/ca-bundle.pem \
      curl -sS --connect-timeout 10 --max-time 90 https://inference.local/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PONG\"}],\"max_tokens\":256}"' \
    | head -c 400; echo
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    # NOTE: must probe as /usr/local/bin/node — the openrouter policy enforces
    # `binaries`, so a curl probe gets "CONNECT tunnel failed, response 403"
    # even when the policy is active and the real (node-issued) traffic passes.
    echo "    --- openrouter.ai key check (node through the egress proxy): ---"
    docker exec -u 0 -e K="$OPENROUTER_API_KEY" "$CONTAINER" sh -c '
      nsenter -t '"$NEWPID"' -n env NODE_USE_ENV_PROXY=1 \
        https_proxy=http://10.200.0.1:3128 HTTPS_PROXY=http://10.200.0.1:3128 \
        NODE_EXTRA_CA_CERTS=/etc/openshell-tls/openshell-ca.pem \
        /usr/local/bin/node -e "fetch(\"https://openrouter.ai/api/v1/key\",{headers:{Authorization:\"Bearer \"+process.env.K}}).then(r=>r.text()).then(t=>console.log(t.slice(0,300))).catch(e=>{console.error(\"ERR\",e.cause?.message||e.message);process.exit(1)})"' \
      || echo "    (key check failed — verify the key, then re-test over Telegram)"
  fi
else
  echo "    NOTE: new gateway pid not found — verify by hand over Telegram."
fi

echo "==> Done. Final word = a live prompt over Telegram (see CLAUDE.md 'Verifying a change')."
