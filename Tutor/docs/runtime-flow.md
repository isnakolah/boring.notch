# Calla Tutor runtime flow

What actually runs, where it runs, and how to prove it end to end. Read
[agent-context.md](agent-context.md) first for the authority model; this
document is the operational counterpart — paths, config keys, the exact call
chain, and the failures that look like bugs but are not.

Naming is load-bearing. The capability is `tutor`. `desktop-tutor` is the
retired identity and appears only in migration code. Three names changed with
it, and all three must move together or the round trip dies silently:

| Thing | Retired | Current |
| --- | --- | --- |
| Plugin id / config entry | `desktop-tutor` | `tutor` |
| Node invoke command | `desktop-tutor.host` | `tutor.host` |
| Node capability | `desktop-tutor-host` | `calla-tutor-host` |
| Unix socket directory | `~/Library/Application Support/OpenDesktopTutor` | `~/Library/Application Support/CallaTutor` |

## Topology

Two machines, one plugin, loaded twice with different roles.

```text
Gateway device (nomonhomelab, Linux)         Mac (Calla Mac)
────────────────────────────────────         ───────────────
openclaw gateway --port 18789                openclaw-node  (LaunchAgent
  bind: loopback                               com.calla.openclaw-node-host)
  auth: none                                     │
  plugins.load.paths ──┐                         │ wss://…ts.net:443
    apps/tutor/integrations/openclaw             │
  entries.tutor.role: gateway                    ▼
  entries.tutor.nodeId: <paired node>          plugins.load.paths ──┐
    │                                            apps/tutor/integrations/openclaw
    │ registers 8 tutor_* tools                entries.tutor.role: node
    ▼                                            │
tailscale serve                                  │ registers node host command
  https://nomonhomelab.tailec0dca.ts.net         │   tutor.host, cap calla-tutor-host
    → 127.0.0.1:18789  (tailnet only)            ▼
                                               ~/Library/Application Support/
                                                 CallaTutor/tutor-host.sock
                                                   │
                                                   ▼
                                               Calla TutorHost.app  (LaunchAgent
                                                 com.calla.tutor-host)
                                                 ├─ window capture (Screen Recording)
                                                 ├─ overlay helper (cursor + tooltip)
                                                 └─ App Pack resolve / approve / verify
```

The Gateway is loopback-bound and has no login. Tailscale Serve is the only
external route and is tailnet-scoped. The Mac holds every screen permission,
every coordinate, and all action authority.

## The call chain, file by file

A single `tutor_guide` from the model:

1. **Tool executes on the Gateway.**
   `integrations/openclaw/src/tools.mjs:318` builds an envelope with
   `buildTutorEnvelope` (`src/protocol.mjs:165`): `{protocol_version: 2,
   request_id, operation, session_id, payload}`. `session_id` is stripped out of
   the payload and promoted to the envelope.
2. **Payload validation.** `validateToolPayload` (`src/protocol.mjs:117`)
   enforces per-operation shape, then `findForbiddenCoordinatePath`
   (`src/protocol.mjs:62`) walks the whole payload rejecting any
   coordinate-shaped key. Exactly one path is exempt per tool
   (`exemptRegionPath`, `src/protocol.mjs:84`): `region` for `tutor_guide`,
   `target_hint.region` for `tutor_point`, nothing for anything that can act.
3. **Pre-call policy.** `before_tool_call` (`src/policy.mjs:11`) re-runs the same
   region and coordinate checks independently of the tool, and turns
   `tutor_propose_action` into a Gateway approval prompt
   (`src/policy.mjs:44`).
4. **Pack-canonical descriptors.** `tutor_point`, `tutor_propose_action`, and
   `tutor_verify` replace any model-supplied descriptor with the canonical one
   from the local pack store (`requireCanonicalDescriptor`,
   `src/local-retrieval.mjs`). Retrieval never leaves the Gateway at all: the
   installed lesson is rendered to a compact card and injected as turn context
   (`lessonCard`, `retrieveLessonByID`), so there is no retrieval tool.
5. **Node invoke.** `api.runtime.nodes.invoke({nodeId, command: "tutor.host",
   params: envelope, timeoutMs})`. A guide carrying `wait_for_change` gets a
   longer transport timeout so the wait is not cut off mid-wait.
6. **Node side.** The same plugin loaded with `role: node` registered
   `tutor.host` (`index.mjs`, `registerNodeHostCommand`).
   `handleTutorNodeHostCommand` (`src/node-host.mjs:77`) revalidates the
   envelope, opens the Unix socket, writes one newline-delimited JSON line, and
   reads one back, capped at 1.5 MiB.
7. **TutorHost.** `TutorHostController.handle` (`apps/macos/TutorHost/Sources/
   CallaTutorHost/TutorHostController.swift:155`) dispatches on `operation`
   (lines 175–182) and rejects raw coordinates a third time, locally
   (line 280, `invalid_coordinates`).
8. **Back up.** The node returns the host's JSON **as a string** — returning a
   parsed object makes the invoke come back `{ok: true, payloadJSON: null}` and
   silently drops the entire response (`src/node-host.mjs:71`).
   `observationResult` (`src/tools.mjs:284`) then lifts the JPEG base64 out of
   the JSON text and re-emits it as an image content block, so the model can
   actually see it; `tutor_guide` does the same for the `next_observation` it
   carries back.

Response nesting is easy to get wrong when probing by hand. `openclaw nodes
invoke` returns `{ok, payload}` where `payload` is the host envelope
`{ok, request_id, payload}` — the operation result is two levels down.

## Configuration, both sides

Gateway — `~/.openclaw/openclaw.json` on the Gateway device:

```json
{ "plugins": {
    "load": { "paths": ["/srv/app/.openclaw/apps/tutor/integrations/openclaw"] },
    "entries": { "tutor": { "enabled": true, "config": {
      "role": "gateway",
      "nodeId": "<paired node id>",
      "stateDirectory": "/home/<user>/.openclaw/tutor",
      "requireOwnerIdentity": false } } } } }
```

Mac — `~/.openclaw/openclaw.json`:

```json
{ "plugins": {
    "load": { "paths": ["/Users/<user>/dev/calla-openclaw/apps/tutor/integrations/openclaw"] },
    "entries": { "tutor": { "enabled": true, "config": {
      "role": "node",
      "stateDirectory": "~/.openclaw/tutor",
      "requireOwnerIdentity": false } } } } }
```

`role: both` is refused unless `developmentMode` is explicitly true
(`src/protocol.mjs:208`). `nodeId` is required on the Gateway; without it every
tool throws before touching the network (`src/tools.mjs:342`).

`bootstrap-calla-mac.sh` runs `openclaw plugins install <path>`, which **copies**
the plugin into `~/.openclaw/extensions/tutor` instead of referencing the
checkout. That snapshot does not track edits. For development, uninstall the
copy and point `plugins.load.paths` at the checkout, the way the Gateway does:

```bash
openclaw plugins uninstall tutor --force
openclaw config patch --stdin <<'EOF'
{"plugins":{"load":{"paths":["/Users/<user>/dev/calla-openclaw/apps/tutor/integrations/openclaw"]},
 "entries":{"tutor":{"enabled":true,"config":{"role":"node","stateDirectory":"~/.openclaw/tutor","requireOwnerIdentity":false}}}}}
EOF
launchctl kickstart -k "gui/$(id -u)/com.calla.openclaw-node-host"
```

Never leave both an `extensions/tutor` copy and a `load.paths` entry in place —
two registrations of one plugin id.

## Mac processes

| LaunchAgent | Runs | Log |
| --- | --- | --- |
| `com.calla.openclaw-node-host` | `apps/tutor/scripts/calla-node-host.sh` → `openclaw-node`, env `CALLA_NODE_GATEWAY_HOST/PORT/TLS`, `CALLA_NODE_DISPLAY_NAME="Calla Mac"` | `~/Library/Logs/Calla/node-host.log` |
| `com.calla.tutor-host` | `apps/tutor/scripts/calla-tutor-host.sh` → `~/Applications/Calla TutorHost.app` | `~/Library/Logs/Calla/tutor-host.log` |

Both plists hardcode the checkout path they were installed from. Moving the
checkout means re-running `./scripts/bootstrap-calla-mac.sh --install --yes`.

## Enrollment

The Mac never receives a Gateway token or a copied node id. It connects, appears
as pending, and `tools/calla_node_enroller.py` on the Gateway approves exactly
one pending device+node whose display name is `Calla Mac`, then patches
`plugins.entries.tutor.config.nodeId` itself (`calla_node_enroller.py:83`). It
refuses to act on two matches. The node id is stable across re-pairing because
it derives from the Mac's node identity, not the pairing event.

**The gateway caches a node's caps and commands in `~/.openclaw/nodes/paired.json`
at approval time.** Rename a command or capability and the node advertises the
new one while the gateway keeps showing the old — `openclaw nodes describe`
reports the new cap under `Pending caps`, and every invoke fails. Re-approval,
not a restart, is the fix:

```bash
openclaw nodes remove --node <id>
# Mac's KeepAlive node reconnects within seconds
python3 tools/calla_node_enroller.py --watch
```

## Verifying a change

Source contracts, offline. Needs a venv — the repo ships none and the toolchain
needs PyYAML and jsonschema:

```bash
cd apps/tutor
python3 -m venv .venv && .venv/bin/pip install -e .
PYTHON=.venv/bin/python make test        # 4 bridge + 19 plugin + 19 tools + 7 packctl
```

The whole Mac path without the Gateway — observe with a real capture, guide,
narrate, and the three coordinate rejections:

```bash
.venv/bin/python tools/calla_guide_probe.py \
  --bundle-id org.blenderfoundation.blender --capture-out /tmp/observed.jpg
```

The real round trip, from the Gateway across the tailnet. Focus an allowlisted
application first:

```bash
openclaw nodes describe --node <id>      # expect Caps to include calla-tutor-host
openclaw nodes invoke --node <id> --command tutor.host --timeout 60000 --params '{
  "protocol_version":2,"request_id":"probe-0001-aaaa","operation":"observe",
  "session_id":"probe-session-01",
  "payload":{"include_capture":true,"allowed_bundle_ids":["org.blenderfoundation.blender"]}}'
```

Then guide at the `snapshot_id` that returned, and expect a `guide_receipt` with
`evidence: ["model_region_on_live_window"]` and Calla's cursor on the Mac.

Linux-only proof is not proof. `make test` validates contracts and installer
logic; only a Mac round trip validates capture, overlay, and permissions.

## Failures that are not bugs

- **`app_not_allowed`** — the effective allowlist is the *intersection* of the
  Mac's own allowlist (`TutorSettings.swift:122`, default
  `["org.blenderfoundation.blender"]`, editable only in Calla's menu bar) and
  the call's `allowed_bundle_ids`, further restricted to an application focused
  recently enough to still be the lesson subject
  (`LessonSubject.mostRecent`). Naming a bundle id in a tool call grants nothing.
- **`invalid_region` / `invalid_coordinates`** — a pixel rectangle, a raw
  coordinate, or a region attached to an action. Rejected independently at the
  policy hook, the tool, and the Mac. All three are intentional.
- **`TUTOR_HOST_UNAVAILABLE`** — the socket is absent or refusing. Usually the
  host is running from a different checkout and listening on the other socket
  path. Confirm with `lsof -p $(pgrep -f 'Calla TutorHost.app')`.
- **502 / `1012 service restart` in `node-host.log`** — the Gateway restarted;
  the node reconnects on its own. Only a persistent 502 is a real problem.
- **Screen Recording revoked after every rebuild** — the signing identity is
  missing. `./scripts/calla-signing-identity.sh --ensure` creates a local
  certificate so the grant binds to the identity rather than the code hash;
  rebuilds then keep it.
- **`AGENTS.md` unreadable on macOS** — fixed, and here so an old clone is
  recognisable. The repository root used to track `AGENTS.md` (a file) and
  `agents.md` (a symlink to it), plus the same pair for `CLAUDE.md`. On a
  case-insensitive filesystem each pair is one path with two index entries: git
  checks out the regular file, the symlink resolves to itself, and reading it
  fails with `ELOOP` — which showed as a permanent typechange on `agents.md` in
  `git status`. The lower-case aliases are now untracked and gitignored. A clone
  predating that still shows the typechange; `git rm --cached agents.md
  claude.md` clears it.

## Where a teaching step's seconds go

Measured, not estimated. `tools/calla_step_timing.py` prints this split; run it
on the Gateway, or over ssh from the Mac:

```bash
ssh gateway 'python3 - --last 5' < tools/calla_step_timing.py
```

The whole delay is model calls. A step used to cost 3–4 of them at 4–13 seconds
each; backend setup is ~2.4 s, CLI boot ~1.6 s, and the Mac ~0.15 s. Optimising
anything but the call count is optimising noise, which is why the loop guidance
states a call budget and every step's check is one turn against a crop rather
than three against a window. The Mac used to advance planned steps by itself,
which was faster still and checked nothing: the cursor moved on whether or not
the step had worked. Checking the learner's work is the point, so the step now
costs a turn and the crop is what keeps that affordable.

The most expensive single thing in a step is the capture: one 1600-pixel window
JPEG cost about **27,000 input tokens and 13 seconds** of the model reading it —
the context jumped 23k → 50k on the call that received it. The default long edge
is 1024 for that reason, and `tutor_observe` takes an optional normalized region
so one panel can be sent instead of a window.

**Two transcripts exist, and only one of them holds the images.** OpenClaw's
session store (`~/.openclaw/agents/calla/sessions/*.jsonl`) carries no image
bytes at all — `observationResult` (`src/tools.mjs`) lifts the base64 out and
leaves `delivered_as: "image_content_block"`. The codex rollout
(`~/.openclaw/agents/calla/agent/codex-home/sessions/…`) is the conversation the
model actually receives, and it accumulates every capture: one session held 18
images and 4.9 MB of base64, reaching 240k tokens against a 258k window.

That rules out the obvious fix. Plugin hooks cannot rewrite history —
`before_prompt_build` and `agent_turn_prepare` return only system-prompt and
prepend/append context — and `tool_result_persist`, the one hook that can
replace a message, transforms OpenClaw's *persisted* copy, which already has no
images in it. The rollout belongs to the codex app-server and is out of the
plugin's reach. What bounds it instead is a session per lesson, a smaller
capture, and a step check that crops to the region just guided rather than
sending the window again.

## Changing the protocol

`PROTOCOL_VERSION` is checked on both sides (`src/protocol.mjs:188`), and the
Swift host validates it too. A bump means: plugin, TutorHost rebuild and
reinstall, and a node reconnect. Adding an operation means adding it to
`TUTOR_TOOL_NAMES`, `TOOL_TO_OPERATION`, the tool definitions in `tools.mjs`,
the `contracts.tools` list in `openclaw.plugin.json`, and the Swift dispatch —
all five, or the tool exists and does nothing.

## Boring Engine mode (protocol v4)

`runtimeMode=engine` is one-way authority reduction for embedded Boring. The
Engine creates a run/generation only after persisting it, sends typed Host
commands, validates Host receipts against current identity, and advances only
on deterministic `satisfied`. `unsatisfied`/`unknown` hold step and may request
supplementary feedback. Model output is never parsed as a target, command,
coordinate, verifier result or progression decision.

Host captures only exact currently-frontmost allowlisted target window for
feedback. It returns JPEG bytes over owner-local IPC and never writes image
files. Engine validates, encrypts, persists capture plus pending request, then
routes. Gateway feedback is a separate owner-only socket using
`runEmbeddedAgent(images:, disableTools:true)` with no Tutor tools/node calls.

Gateway/node snapshot transport remains `tutor.host`, but permitted Engine
operations are capability, catalogue, lifecycle, runtime and health snapshots.
Any legacy teaching/model operation is unavailable in Engine mode. Standalone
mode retains legacy behavior for rollback and is never entered by Boring.
