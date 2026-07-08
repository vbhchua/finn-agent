#!/usr/bin/env bash
set -euo pipefail

# tools/build-finn-base.sh
#
# Build the finn base image `nemoclaw-finn-base:2026.6.10` that
# `Dockerfile.finn-2026.6.10` starts `FROM`. This image is a LOCAL build — it is
# NOT in any registry — so on a fresh host (new EC2, new laptop) it must be built
# BEFORE `nemoclaw onboard --from ./Dockerfile.finn-2026.6.10`, or the onboard
# fails with:
#
#     pull access denied for nemoclaw-finn-base, repository does not exist
#     or may require 'docker login'
#
# (Docker treats the missing local tag as a registry ref and tries to pull it.)
#
# What it does: clone a PINNED NemoClaw v0.0.68 checkout, apply the vendored
# 1-line chat-send run-id tolerance patch (NemoClaw's bundled patches only cover
# OpenClaw <= 2026.6.8; 2026.6.9 moved the callsite), then build the full NemoClaw
# production image for OpenClaw 2026.6.10. See Dockerfile.finn-2026.6.10's header
# and SETUP.md ("One-time: build the 2026.6.10 base image") for the full rationale.
#
#   ./tools/build-finn-base.sh          # build if missing (idempotent — skips if present)
#   FORCE=1 ./tools/build-finn-base.sh  # rebuild even if the tag already exists
#
# Env overrides:
#   BASE_TAG          image tag to produce (default nemoclaw-finn-base:2026.6.10)
#   OPENCLAW_VERSION  OpenClaw version to build (default 2026.6.10)
#   NEMOCLAW_REF      NemoClaw git tag to pin (default v0.0.68 — the verified combo)
#   WORKDIR           where to clone+build (default a fresh temp dir; wiped each run)
#
# NOTE: build natively on the target host so the image arch matches. Do NOT
# `docker save`/`load` an arm64 (Apple Silicon) image onto an x86_64 EC2. To reuse
# a prebuilt image across instances, push it to a registry (e.g. ECR) and, on each
# host, `docker pull` it and re-tag to $BASE_TAG before onboarding (nemoclaw onboard
# has no --build-arg, so the FROM tag must resolve locally) — see SETUP.md.

BASE_TAG="${BASE_TAG:-nemoclaw-finn-base:2026.6.10}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-2026.6.10}"
NEMOCLAW_REF="${NEMOCLAW_REF:-v0.0.68}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
PATCH="$REPO_ROOT/patches/nemoclaw-2026.6.x-chat-send-runid.patch"

command -v docker >/dev/null || { echo "ERROR: docker not found on PATH." >&2; exit 1; }
command -v git    >/dev/null || { echo "ERROR: git not found on PATH." >&2; exit 1; }
[ -f "$PATCH" ] || { echo "ERROR: vendored patch not found: $PATCH" >&2; exit 1; }

# Idempotent: if the tag already exists locally, we are done (unless FORCE=1).
if [ "${FORCE:-0}" != 1 ] && docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "==> $BASE_TAG already present locally — nothing to do (FORCE=1 to rebuild)."
  echo "    Next: nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn"
  exit 0
fi

WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/nemoclaw-finn-base-build}"
echo "==> Base tag:        $BASE_TAG"
echo "==> OpenClaw:        $OPENCLAW_VERSION"
echo "==> NemoClaw ref:    $NEMOCLAW_REF (pinned)"
echo "==> Patch:           $PATCH"
echo "==> Work dir:        $WORKDIR (wiped + fresh clone each run)"
echo "==> Building natively for: $(uname -m)"
echo "    (needs outbound HTTPS to github + ghcr + npm during the build)"

rm -rf "$WORKDIR"
git clone --branch "$NEMOCLAW_REF" --depth 1 https://github.com/NVIDIA/NemoClaw.git "$WORKDIR"

echo "==> Applying vendored patch ..."
git -C "$WORKDIR" apply "$PATCH"

echo "==> docker build (this pulls the NemoClaw sandbox-base + OpenClaw sources + npm; ~minutes) ..."
docker build -t "$BASE_TAG" \
  --build-arg OPENCLAW_VERSION="$OPENCLAW_VERSION" \
  --build-arg NEMOCLAW_WEB_SEARCH_ENABLED=1 \
  -f "$WORKDIR/Dockerfile" "$WORKDIR"

echo ""
echo "==> Built $BASE_TAG ($(docker image inspect "$BASE_TAG" --format '{{.Os}}/{{.Architecture}}'))."
echo "    Next: nemoclaw onboard --from ./Dockerfile.finn-2026.6.10 --name finn"
echo "    Then: ./setup-finn.sh   (+ the runmods — see README golden path)"
