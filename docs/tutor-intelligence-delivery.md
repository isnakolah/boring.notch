# Tutor intelligence delivery record

Updated 2026-08-26. This is an evidence ledger, not a completion claim.

- Current Boring implementation commit: `13da5feeda4027818506d28deeb2946b386efb83`
- Latest review-lifecycle implementation commit: `22654ee081a76d97ce7b17809a3cd408d7d31e8b`
- Portable `Tutor/` subtree split: `5d308ad59f8dc64be3b1ab1a3911ffdcf58e2078`
- Calla branch: `feat/boring-owned-tutor-intelligence`
- Calla branch commit: `5d308ad59f8dc64be3b1ab1a3911ffdcf58e2078`
- Protocol: v4, accepted range v2-v4
- Installed Gateway release: `boring-b595bae4fb7d2fe1f3b6`
- Installed Gateway release digest: `d371d433e19b286cc01c8f663395ea0e4c11ba618be762cc228bd18460c105a0`
- Installed Gateway archive digest: `6e3b7372aa963dbc683d43a1e4390040223de6710bc0c3a52836421b08cf43b1`
- Installed node contract digest: `05f2954d82da515d17049dac00da2294ca60f7d68e03fb868e0cf3e1a7aaa0b9`

Published branches:

- `fork/feat/tutor-intelligence-control-plane`
- `calla-openclaw origin/feat/boring-owned-tutor-intelligence`

No pull request created. `origin` for Boring was not pushed.

Verification retained for this record: Swift/Node/Python suites passed;
installer suite passed; signed `/Applications/boringNotch.app` and embedded
Engine passed deep signature verification; installed Engine/Host/Overlay ran;
owner-only Host and Engine ingress sockets existed. Installed migration created
v5 canonical Store rows for exact runtime revision
`org.calla.tutor.blender@0.3.0` and four Boring learning records; legacy source
copies remain under `legacy-import/v1`. Gateway plugin loaded from matching
release; real `refresh-runtime` advanced the canonical manifest from legacy
import to Gateway epoch `gateway-f6775429-1ae4-4fac-be9b-d03ef5ae1a03`, sequence
`18`. Gateway feedback socket completed a real tool-free image request with
strict JSON. Local `agy` screenshot staging has synthetic JPEG tests proving
0700/0600 staging, `agy --print` `@filename` attachment reference, no
`file://`/base64/tool permission argument, startup/defer cleanup, and no
resident-host attachment route. Real target-window, local visual-model, and
Blender course acceptance remain separate evidence gates.

## Remaining work and evidence gates

### Deploy latest source

The signed installed app and Gateway above include review lifecycle commit
`22654ee`, but predate source commit `13da5fe`. Rebuild/redeploy Release from
`13da5fe`, promote its exact embedded Gateway archive, then record resulting
release, archive, and node-contract digests. Invoke installed
`calla-course.sh refresh-runtime` with no stdin and prove it sends
`{"version":1,"command":"refresh-runtime","payload":{}}`, then confirm
Engine ingress accepts fresh lifecycle/runtime snapshots.

### Course review and publication

`ready_for_review` presentation is implemented: it is owner-only, never shown
in learner surfaces, displays bounded digest/compiler/contract/validation/
preflight/lesson facts, and disables learner start/resume actions. Manual UI
review of this installed screen remains unproven.

Gateway default preflight currently verifies staged artifact only and labels
its receipt accordingly. It is **not** a target-backed Blender 5.2 preflight.
Implement/wire an attested real Blender preflight adapter before claiming this
plan's preflight requirement complete. A ready course exists but has not been
published: publication requires explicit owner review and Publish confirmation;
do not publish it automatically. After authorized publish, prove atomic runtime
replacement while an existing run stays pinned.

### Installed acceptance still required

- Real Blender 5.2 deterministic clean-pass, fail, unknown, restart, and
  pinned-revision behavior.
- Exact target-window-only Screen Recording capture; encrypted history file;
  on-demand History reveal; no plaintext or base64 in app/Gateway logs.
- Real local `agy` visual feedback using staged JPEG attachment, attribution,
  and no model filesystem/tool authority.
- Intentional local-provider failure proving one visible Gateway fallback;
  Gateway-selected outage proving no local fallback.
- Missing capture permission, wrong focus, protected/blank capture, missing or
  corrupt exact runtime, pending-request stop/restart, and late-reply races.
- Migration/restart proof from existing Boring JSON state, including backup,
  canonical store/projections, and idempotent recovery.
- Manual Tutor UI sweep: Settings destinations, history pagination/search,
  review Publish confirmation, keyboard/VoiceOver/focus, contrast, reduced
  motion, long content, narrow notch, and Settings resizing.
- Final release evidence: deep signatures for app/Engine/Host/overlay/node/
  Gateway resources, app/node/Gateway restart recovery, screenshots and
  sanitized logs, final SHAs/digests, and retained exact command output.

Automated source matrix is current: `swift test --package-path Intelligence`
passed 156 tests with two opt-in live `agy` tests skipped; `swift test
--package-path CallaContracts` passed 5; root `swift test` passed 75;
`PYTHON=.venv/bin/python make -C Tutor test`, Release build, and `git diff
--check` passed. This is source proof only, not installed end-to-end proof.
