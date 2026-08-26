# Calla migration status

`Tutor/` is Boring-owned source imported from Calla OpenClaw. `Tutor/LICENSE`
and `Tutor/NOTICE.md` preserve Apache-2.0 attribution.

Implemented foundation:

- Embedded `BoringCallaEngine.xpc`, separate from `BoringNotchXPCHelper`.
- Boring-owned `calla*` preferences; no legacy preference import.
- Live whole-preference XPC snapshots, private Boring Calla runtime directory,
  owner-only `tutor-host.sock`, and permission status API. The engine launches
  Boring-bundled TutorHost plus overlay; neither presents its old menu bar or
  settings window. Runtime files never read `~/Library/Application Support/CallaTutor`.
- Right-header `Calla` tab beside `Shelf`; one Settings `Tutor` row.
- Calla tab starts/resumes/stops courses and Ask through XPC. Tutor Settings
  owns course visibility and Calendar event bindings. Eligible event bindings
  start a course plus event-bounded Pomodoro; direct Calla starts do not.
- Embedded OpenClaw plugin, packs, agent workspace, and only runtime-needed
  Tutor scripts. Retired bootstrap, setup, signing, and separate-host scripts
  are excluded from Boring bundles.
- Every Boring build bundles one immutable Gateway release archive. Installed
  Boring launch requests its private `nomonhomelab` update; same manifest
  returns without a Gateway transaction. Debug keeps its separate staged
  artifact route. No public host picker or repair path exists.

**Superseded for the copilot.** The call copilot now chooses between that Gateway and
a local provider (Google's Antigravity CLI on this Mac), local by default, with
automatic fallback to the Gateway and a badge in the notch saying which answered. The
Gateway's own route is unchanged and is still the only remote one allowed. Tutor
courses are untouched. See [intelligence.md](intelligence.md).
- Deployment validation for engine and embedded Tutor resources.
- Gateway release builder/installer with digest, protocol-range, pack/contract
  verification, configuration backup/rollback, stable `current` adapters,
  stale-node contract release, and three-release retention. Gateway sends the
  internal-only v2/v3 capability handshake before its first Calla prompt. A
  successful Gateway update now proves Gateway RPC, active Tutor plugin,
  course-control socket, and paired-node `session_start`; first-release and
  existing-release failures restore config/packs/current state.

Runtime corrections, 2026-08-17:

- Both children's stdio is redirected to `<root>/logs/{tutor-host,node-host}.log`.
  Before this the only node log on disk was the one the retired
  `com.calla.openclaw-node-host` agent wrote, so disabling that agent also
  blinded `BackendStatus`. `StepTiming` moved to the same 0700 root; it is the
  one diagnostic that records a rectangle.
- Permission state is a receipt, `<root>/host-status.json`, written by
  `TutorSettings.refreshPermissionStatus` and read by the engine. TCC grants are
  per executable and CallaTutorHost is what captures, so the engine's own
  `CGPreflightScreenCaptureAccess` was reporting the XPC service. Deliberately a
  file and not a socket call: the UI polls status every 2-4s and a socket round
  trip would block on the host's main actor, which a lesson turn holds for tens
  of seconds. `request_accessibility` now routes to the host for the same reason.
- `isRunning` is set once the host is up, before the node is started. A missing
  plugin file used to leave the engine permanently "still starting" with a
  healthy host, refusing every command.
- `hostReady` (a socket connect probe) is separate from `gatewayReachable`. The
  notch reports `.degraded` when the host is up and the Gateway is not, because
  cached courses and the fast lesson path need no Gateway.
- `foreignNodeProcess` refuses to start a second node, and `detectConflicts`
  reports a legacy host or node as a diagnostic. Detection only; nothing is
  killed.
- `CallaTutorHost` is named "Boring Notch Tutor" in the Screen Recording pane.
  It previously shared "Boring Calla Engine" with the XPC service, so the two
  rows were indistinguishable. `CFBundleIdentifier` is unchanged, so existing
  grants survive.

Local proof, 2026-08-13:

- `PYTHON=.venv/bin/python make -C Tutor test`: pack, Blender bridge,
  OpenClaw plugin, Tutor tooling, Swift host, and pack compiler suites pass.
- `PYTHONPATH=Tutor/Gateway/installer Tutor/.venv/bin/python -m unittest
  discover -s Tutor/Gateway/installer/tests -v`: 12 installer tests pass.
- Release Boring build passes; `codesign --verify --deep --strict` passes.
  Bundle contains engine XPC, host, overlay, resource plugin/packs, and
  Gateway release archive. A locally launched Release engine produced an
  owner-only socket and accepted a v2/v3 `session_start` receipt.
- No runtime Boring bundle reference points to the retired Calla checkout.

Not cut over:

- Existing macOS `CallaTutor` data and app remain untouched.
- Existing Calla launch agents are disabled and unloaded by explicit
  `scripts/calla/runtime-install.sh`; their plists, logs, app, and data are
  never deleted. `launchctl disable` is used rather than `bootout` alone
  because bootout does not survive login: both installs would start a node
  named `Calla Mac`, the Gateway evicts the duplicate, `KeepAlive` respawns it,
  and the pair flap indefinitely. Reverse with
  `launchctl enable gui/$UID/com.calla.tutor-host` and the same for
  `com.calla.openclaw-node-host`.
- Real Gateway promotion, installed production Boring deployment, Screen
  Recording approval, automatic re-pair proof, and real focused Blender lesson
  remain acceptance gates. Do not remove `apps/tutor` from Calla repository
  before those gates pass on `nomonhomelab`.
- Current private Release uses `Calla Local Signing` and disables hardened
  runtime because local signing cannot satisfy library validation for Boring's
  embedded OpenSSL framework. Restore Developer ID signing and hardened runtime
  together before external distribution.

## Tutor Engine cutover, protocol v4

Boring mode is now `runtimeMode=engine`. `BoringCallaEngine` owns canonical
Tutor rows in CallaStore, encrypted target-window history, deterministic run
state, provider routing and publication control. TutorHost is capture,
observation, verifier and overlay executor only. It has no model process,
shell relay or durable Tutor writer in engine mode. Standalone remains an
explicit Tutor-only rollback mode; Boring cannot select or fall back into it.

Gateway node still exposes `tutor.host` for pairing compatibility, but only
for capability, catalogue, lifecycle, runtime and health snapshots. It forwards
those bounded, sequenced snapshots to Engine ingress. Model-visible operations
(`observe`, `guide`, `plan`, `narrate`, `point`, `verify`, learning writes and
actions) fail with `OPERATION_NOT_AVAILABLE_IN_ENGINE_MODE`.

An exact published runtime revision is required for a new run and continuation.
Missing, stale, invalid or incompatible runtime blocks progression and requests
resync; no cached older revision and no provider answer can replace it. Active
runs stay pinned while a reviewed revision is explicitly published.

Tutor history captures are AES-GCM ciphertext files outside SQLite. Engine
creates a this-device-only Keychain key, writes and fsyncs a random temporary
ciphertext, renames it, then atomically commits capture metadata plus a pending
feedback row. Any capture/key/DB/disk error sends nothing. History is retained
until app data is manually removed after quitting; UI intentionally has no
delete or pruning control.

At first Engine launch, only Boring-owned JSON compatibility inputs are copied
byte-for-byte to `legacy-import/v1/` and imported domain-by-domain. Standalone
`~/Library/Application Support/CallaTutor` is never read or changed. Engine then
writes compatibility projections for TutorHost/rollback; TutorHost does not
write Boring Tutor JSON.

See [Tutor control-plane plan](plans/tutor-intelligence-control-plane.md) and
[operator runbook](tutor-operator-runbook.md).
