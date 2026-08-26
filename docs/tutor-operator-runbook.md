# Tutor Engine operator runbook

## Health checks

Run after signed Boring install and matching Gateway promotion:

```bash
codesign --verify --deep --strict /Applications/boringNotch.app
codesign --verify --deep --strict /Applications/boringNotch.app/Contents/XPCServices/BoringCallaEngine.xpc
test -S "$HOME/Library/Application Support/boringNotch/Calla/tutor-host.sock"
test -S "$HOME/Library/Application Support/boringNotch/Calla/engine-ingress.sock"
ssh isnakolah@nomonhomelab 'export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"; openclaw plugins inspect tutor; test -S "$HOME/.openclaw/tutor/feedback-control.sock"'
```

Settings must show Host, node, Gateway authoring, Gateway feedback and local
`agy` separately. Gateway outage may disable sync/feedback but must not mark a
cached exact deterministic course offline.

## Feedback rules

Screen Recording is required. Ask remains disabled while capture unavailable or
feedback is pending. Re-focus exact allowlisted target before asking: feedback
never captures desktop, display, menu bar, notifications or previously-focused
window. Both Local `agy` and Gateway can transmit target screenshot to remote
model services; Local means local CLI/session ownership, not on-device inference.

For every feedback request inspect History: selected route, actual route, model,
latency, fallback, terminal state and capture indicator. Reveal captures only on
owner click. Do not copy raw request/image/model output into logs or tickets.

## Recovery

- Missing exact runtime: use **Refresh runtime**. Do not start older runtime.
- Capture/key/storage error: keep deterministic lesson active, repair Screen
  Recording or disk/Keychain state, then submit again. Do not reset DB or create
  replacement history key.
- Local attachment unsupported/unavailable: local selection can fall back once
  to Gateway. Gateway selection never falls back local.
- Stop/restart during reply: request becomes cancelled/stale. It must never be
  resent automatically or render against new run generation.
- Gateway release failure: installer restores previous current pointer/config.
  Keep Boring installed app and DB unchanged while investigating receipt.

## Rollback

Quit Boring before manual app-data work. Keep v5 database, encrypted captures,
pre-migration backup, compatibility projections and standalone Calla data intact.
Do not downgrade schema or delete history. Use explicit standalone deployment
only outside Boring; no Boring configuration activates it.
