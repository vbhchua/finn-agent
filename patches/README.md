# patches/

Local modifications to **NemoClaw** needed to build finn's OpenClaw **2026.6.10** base image.
NemoClaw deliberately pins OpenClaw and ships source patches that — as of **NemoClaw v0.0.68** —
only cover OpenClaw **≤ 2026.6.8**. 2026.6.9 restructured the chat-send `runQueuedFollowup`
run-id callsite, so a stock build fails with *"followup runner run-id shape not recognized."*

- **`nemoclaw-2026.6.x-chat-send-runid.patch`** — a 1-line regex tolerance in
  `scripts/patch-openclaw-chat-send.js` so the run-id-preservation patch also matches OpenClaw
  2026.6.9/.10 (`sessionId: effectiveQueued.admissionSessionId ?? run.sessionId`). The inserted
  code is unchanged; the patch still self-verifies and fails closed.

Apply from a NemoClaw **v0.0.68** checkout root, then build the base (see `Dockerfile.finn-2026.6.10`):

```bash
git apply <this-repo>/patches/nemoclaw-2026.6.x-chat-send-runid.patch
```

Drop this once NemoClaw ships 2026.6.9+ support upstream.
