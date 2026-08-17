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
- Deployment validation for engine and embedded Tutor resources.
- Gateway release builder/installer with digest, protocol-range, pack/contract
  verification, configuration backup/rollback, stable `current` adapters,
  stale-node contract release, and three-release retention. Gateway sends the
  internal-only v2/v3 capability handshake before its first Calla prompt. A
  successful Gateway update now proves Gateway RPC, active Tutor plugin,
  course-control socket, and paired-node `session_start`; first-release and
  existing-release failures restore config/packs/current state.

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
