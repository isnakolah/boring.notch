# Boring-owned Tutor Intelligence and Control Plane

Status: accepted implementation plan. 2026-08-26.

## Outcome

Boring Notch owns deterministic Tutor lesson execution, verification, progression,
persistence, encrypted captures, provider routing, history and UI state. Gateway owns
course authoring, compilation, validation, preflight, review readiness and explicit
publication; it may provide tool-free feedback only. TutorHost owns allowlisted target
window capture, deterministic observation/detectors and overlays. Neither Gateway nor
any model may select a target, issue Host commands, act, determine verification, or
advance a lesson.

Local `agy` is default. Owner may globally select Gateway. Local route may fall back
once to Gateway on eligible provider failure; Gateway selection never falls back local.
Both paths disclose that screenshots reach remote model services. Intelligence runs for
learner questions and deterministic fail/unknown only; clean pass never waits for a
model. Capture failures block intelligence, never deterministic lessons.

## Delivery and ownership

- Branch: `feat/tutor-intelligence-control-plane`, based on local `main` baseline
  `1fc9e69`; never merge/rebase nine `origin/main` CI commits.
- Push Boring branch only to `fork`; no upstream push or PR.
- Keep portable Host, TutorKit, Gateway plugin, schemas, scripts, tests and docs under
  `Tutor/` as subtree. Keep Boring XPC, Engine, CallaStore, Intelligence, UI, project,
  build and deployment outside it.
- After portable validation, subtree-split to
  `feat/boring-owned-tutor-intelligence`, push through linked `calla-tutor` checkout
  to `../calla-openclaw` `origin`; record Boring, split and Calla SHAs, protocol and
  Gateway release digest.
- Preserve standalone Tutor as explicit `runtimeMode=standalone`. Boring hardcodes
  `runtimeMode=engine` and fails startup if standalone teaching relays are configured.
- Import current Boring Tutor runtime data only; never touch standalone Calla data.

## Protocol and security contract

Create portable Tutor protocol v4: `TutorControlEnvelope`, `TutorRunIdentity`,
`TutorHostCommand`, `TutorHostEvent`, `TutorFeedbackRequest`, `TutorFeedbackReply`,
`TutorCaptureMetadata`, `TutorVerificationReceipt`, `TutorRunSnapshot`,
`TutorGatewaySnapshot`, `TutorCapabilityHandshake`.

Every state-mutating envelope has protocol version, request/run ID, monotonically
increasing generation, exact course revision, lesson/step, operation, bounded payload
and issue timestamp. Engine accepts event only when all identity fields match current
run. Duplicate IDs return prior result; stale/future events diagnose only.

Reject invalid UTF-8, control/NUL/unsafe bidi, unknown fields, trailing frames and bad
MIME signatures. Limits: control frame 64 KiB; question/answer 800 Unicode chars;
structured context 16 KiB; JPEG owner edge 1024/1600/2048, Q0.85, 3 MiB; Gateway
envelope 5 MiB; Gateway response 16 KiB.

Engine, Host and node sockets use 0700 parent, 0600 socket, peer UID validation,
protocol-range validation and Engine-launch capability token. Gateway snapshots carry
persistent epoch plus monotonic sequence; reject rollback, duplicates, reordering and
digest conflict, request full resync on unknown epoch.

## Intelligence

Extend shared intelligence API with attachments, provider attachment capability,
`IntelligenceTask.tutorFeedback`, per-task ordered routes, total deadline and complete
selected/actual provider attribution. Strict Tutor JSON response contains `message`,
`assessment` (`on_track|needs_help|uncertain`) and `basis`
(`screenshot|verifier|authored`); render only message.

Local selected: `agy` first for 5s, one eligible Gateway fallback using remaining
15-second total budget. Gateway selected: Gateway only, max 12s. No same-provider
Tutor retry. Eligible fallback: missing binary, unauthenticated, quota, transport,
timeout, dead session, invalid contract or unsupported image. Storage/capture/protocol/
safety/invalid-request failures never fallback. Pin request route at creation. Prewarm
local session at run start; close provider sessions on stop, complete, exit or generation
change. `CopilotAdvisor` receives injected provider/factory; Call Copilot Gateway route
remains unchanged.

Capture flow: Host captures only exact focused allowlisted target window and returns
typed screenshot plus verifier facts. Engine validates it, AES-GCM encrypts it, and
atomically commits capture metadata and pending sanitized feedback before transmission.
On storage failure send nothing. `agy` stages random 0600 plaintext in private 0700
workspace with relative random filename, deletes in `defer`, startup scrubs leftovers.
Gateway uses owner-only feedback socket and `runEmbeddedAgent(images:, disableTools:true)`
with no node commands/Tutor tools. Never log prompt/image/base64/response. Persist valid
reply and attribution before rendering; terminal states explicitly include fallback,
timeout, failure, cancellation and stale.

## Lifecycle

Authoring lifecycle: `queued -> compiling -> validating -> waiting_for_blender ->
preflighting -> ready_for_review -> publishing -> published`, with `failed`,
`cancelled`, `archived`. Warnings fail. Review exposes bounded validation/preflight
facts only. Publish is explicit and atomic against exact digest, target, compiler and
preflight invariants; retain previous pack on failure. Runs stay revision-pinned.

Run lifecycle: `idle -> starting -> active <-> feedback_pending -> completing ->
completed`, or `stopped`, `failed`, `blocked_runtime`, `blocked_target`. Engine validates
published exact runtime/target/digest, persists run then commands Host. Satisfied receipt
advances deterministically. Unsatisfied/unknown holds step, persists attempt, shows
authored feedback then optionally starts intelligence. Auto-pass cancels feedback and
advances. Restart produces new run/generation without deleting history.

## Store and migration

Append migration after v4; never edit shipped migrations. Add `tutor_setting`,
`tutor_course_revision`, `tutor_lesson`, `tutor_runtime_manifest`, `tutor_run`,
`tutor_run_event`, `tutor_learning`, `tutor_feedback`, `tutor_capture`,
`tutor_gateway_snapshot`, `tutor_import`, and FTS limited to title/question/parsed
answer. Reject future SQLite versions; no reset/downgrade. Global provider setting
defaults local. No UI deletion/pruning.

Capture ciphertext lives outside SQLite in 0700 attachment directory, files 0600.
Engine keeps this-device-only 256-bit Keychain master key, AES-GCM random nonce, fsync+
atomic rename then DB reference. Missing/wrong key hard-fails capture history, never
replaces key. Startup removes temp/plaintext and aged unreferenced ciphertext; no
preloaded thumbnails, reveal one decrypted capture on demand.

Before Host starts, checkpoint WAL and make 0600 SQLite backup. Copy byte-for-byte
Boring-owned legacy `catalogue.json`, `course-status.json`, `course-runs.json`,
`course-runtime.json`, `learning/*.json` into `legacy-import/v1/`. Validate bounded
shape/ownership/relationships; import each domain transactionally, idempotently by
digest/natural keys, preserving newer canonical rows. Malformed runtime/catalogue blocks
affected course but diagnostics remain available. Legacy files become Engine-generated
Host compatibility projections. Never import `~/Library/Application Support/CallaTutor`.

## XPC and UI

Use shared Codable DTOs and bounded XPC commands for provider preference, feedback
submit/cancel, cursor-paged history, on-demand capture retrieval, explicit publish,
resync and run start/resume/restart/stop. Status reports selected/active provider and
attribution, local/Gateway/node/ingress health, sync timestamps, pinned run identity,
pending feedback, verification, storage/import/capture stats and release versions.

Add Tutor Intelligence settings: provider picker, remote screenshot disclosure, agy
install/version/auth/probe, separate Gateway authoring/feedback health, capture state,
retention notice and no delete control. Add text-only history search, stable 50-item
cursor pagination, labelled terminal states and click-to-reveal capture. Add review
screen with facts and confirmed replacement publish. Active UI disables Ask while
pending/capture unavailable, immediately renders authored trouble feedback, labels model
supplements/fallback, keeps health domains separate and supports VoiceOver, keyboard,
focus, contrast, reduced motion, long/narrow layouts.

## Implementation order

1. Protocol v4 and schemas/tests.
2. Intelligence attachments, routes, attribution and injected Copilot provider.
3. CallaStore migration, repositories, encryption, importer, projections/recovery.
4. Engine progression authority, XPC and status.
5. Host engine-mode capture/verifier/overlay executor.
6. Engine ingress/node snapshot path.
7. Gateway tool-free feedback provider.
8. Review/publication lifecycle.
9. Remove Boring shell relay/direct teaching use while preserving standalone path.
10. Intelligence/history/review/health/active UI.
11. Security/pedagogy/runtime/intelligence/migration/runbook/deployment docs.
12. Automated checks, signed install and real Gateway/Blender acceptance; only then
    split/push coordinated branches.

## Required verification

Run `swift test --package-path Intelligence`, `swift test --package-path
CallaContracts`, root `swift test`, `PYTHON=.venv/bin/python make -C Tutor test`,
`git diff --check`, and Release `xcodebuild` build. Test all storage/migration,
encryption/recovery, protocol/IPC identity, lifecycle, fallback/cancellation, screenshot
confidentiality, UI accessibility and publication cases listed in accepted brief.

Installed acceptance requires signed `/Applications/boringNotch.app`, paired private
Gateway and Blender 5.2: migration/restart, protocol v4/full sync, offline exact cached
run, clean deterministic pass, trouble capture encryption/history reveal, real local and
Gateway feedback, fallback, missing capture/focus handling, pending restart, runtime
block/resync, review then explicit atomic publish, post-restart persistence and all Tutor
controls. Record signatures, process identities, screenshots, sanitized logs, digests,
schema/import status and SHAs. Keep rollback backup/projections/standalone path through
approved rollback window; never downgrade schema or delete encrypted history.
