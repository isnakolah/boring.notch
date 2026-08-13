# Task

Make a Calla Tutor teaching step fast on the Gateway side. A step that needs the
model currently takes ~35s median (p90 42s). About 70% of that is harness
overhead, not thinking. Cut the overhead. Do not change what Calla is allowed to
do.

You are working on the Gateway. The Mac side is already fast (1–200ms) and is
out of scope except for reading its logs as evidence.

## Access

```bash
# Gateway, from the Mac. Reuse the multiplexed control socket.
ssh -o BatchMode=yes -o ControlPath=/tmp/calla-raycast.sock isnakolah@nomonhomelab
```

- Gateway config: `~/.openclaw/openclaw.json` (on the Gateway). The `calla` agent
  is `agents.list[]` entry `id: "calla"`.
- OpenClaw install: `/home/isnakolah/.npm-global/lib/node_modules/openclaw`,
  version `2026.7.1-2`. Bundled docs under `docs/`, minified runtime under `dist/`.
- Plugin source (checked out, editable, this is the repo you commit to):
  `/srv/app/.openclaw/apps/tutor/integrations/openclaw/` — on the Mac the same
  tree is `/Users/isnakolah/dev/calla-openclaw/apps/tutor/integrations/openclaw/`.
- Codex rollouts (per-event timestamps, the ground truth for timing):
  `~/.openclaw/agents/calla/agent/codex-home/sessions/*/*/*/*.jsonl`
- Mac host timings: `~/Library/Logs/Calla/step-timing.log` (on the Mac).
- Paired node id:
  `3d20a9f75b32b194edb551d4c30ea3b5799a06fc44c1e4722b3aad934e5417c2`

## Measured baseline — reproduce these before changing anything

Timing tool already in the repo, run it over ssh:

```bash
ssh -o BatchMode=yes -o ControlPath=/tmp/calla-raycast.sock isnakolah@nomonhomelab \
  'python3 - --last 8 --agent calla' < apps/tutor/tools/calla_step_timing.py
```

Last real lesson session:

```
turn_seconds             n=5   median 35.4  p90 42.4  min 14.0 max 57.1
model_call_wait_seconds  n=18  median  5.4  p90  8.2  min  2.8 max 17.8
model_calls_per_turn     n=5   median  3.0  p90  6.0
cache_hit_fraction       0.89
```

One real turn (12:55:29, 42.4s) splits as: model waits 27.9s, code-mode bridge
10.7s, setup 2.1s, Mac host 0.15s.

Across all 44 rollouts / 380 tool calls, cost per bridged call:

| operation      |   n | median | Mac host does it in | overhead |
| -------------- | --: | -----: | ------------------- | -------: |
| tutor_guide    | 136 |  4.60s | ~80ms               |   ~4.5s  |
| tutor_observe  | 177 |  2.60s | ~30ms               |   ~2.5s  |
| tutor_plan     |  33 |  2.60s | ~2ms                |   ~2.6s  |
| session_status |   2 |  3.70s | never leaves Gateway|   ~3.7s  |
| pure JS, no tool | 56| 0.15s  | —                   |     —    |

Other measured facts:

- Model-visible tool-call names across all 44 rollouts: `{exec: 380, wait: 53}`.
  **Zero** native `tutor_*` calls, ever.
- `openclaw agent --agent calla -m "Reply with the single word: ok"` = 10.5s cold,
  9.8s / 13.7s warm. The rollout accounts for only 5.2–9.0s of that.
- `openclaw nodes list` = 2.5s; `openclaw --version` = 25ms. So ~2.5s of every
  CLI invocation is Gateway connect, before any work.
- Direct to the Mac host over its unix socket: `observe` = 5.5ms.

## Work item 1 — stop routing tutor tools through Codex code mode (biggest win)

This is the main cost. Every tutor call is model-written JS inside codex's `exec`:

```js
const r = await tools.openclaw__tutor_observe({session_id:"calla-lesson", include_capture:true});
```

The tax is the bridge, not the sandbox and not the tailnet — pure-JS execs cost
0.15s, and `session_status`, which never leaves the Gateway, still costs 3.7s.
`tutor_plan` is 2.6s against 2ms of real work.

What the code says (`dist/thread-lifecycle-DSMv62L1.js`):

```js
const CODEX_CODE_MODE_THREAD_CONFIG = {
  "features.code_mode": true, "features.code_mode_only": false,
  "features.apply_patch_streaming_events": true };
const CODEX_CODE_MODE_DISABLED_THREAD_CONFIG = {
  "features.code_mode": false, "features.code_mode_only": false };

function buildCodexRuntimeThreadConfig(config, options = {}) {
  ...
  if (options.nativeCodeModeEnabled === false) { /* returns the DISABLED config */ }
  ...
}
```

and `nativeCodeModeEnabled` is fed from `params.nativeToolSurfaceEnabled`, which
comes from `shouldEnableCodexAppServerNativeToolSurface`
(`dist/provider-capabilities-CYpG67go.js`):

```js
function shouldEnableCodexAppServerNativeToolSurface(params, sandbox, options = {}) {
  if (isCodexMemoryFlushRun(params)) return false;
  const toolsAllow = includeForcedCodexDynamicToolAllow(params.toolsAllow, params);
  if (toolsAllow === void 0) return canCodexAppServerNativeToolSurfaceHonorSandbox(sandbox, options);
  return hasWildcardCodexToolsAllow(toolsAllow) && canCodexAppServerNativeToolSurfaceHonorSandbox(sandbox, options);
}
```

`docs/plugins/codex-harness.md:22-27` documents the intent: code mode is on by
default when no sandbox is active, and "an active OpenClaw sandbox or restricted
tool policy disables native code mode entirely."

**The open question, and your first job.** Calla already has a restricted tool
policy — `tools.profile: "minimal"` plus a 10-entry `alsoAllow` — so by that
documented rule code mode should already be off for it. It observably is not.
Find out why before changing anything. Two hypotheses worth testing first:
`params.toolsAllow` is `undefined` at that call site (the profile/`alsoAllow`
having been resolved into some other field), so the `toolsAllow === void 0`
branch runs and returns true; or `includeForcedCodexDynamicToolAllow` widens the
list. Add temporary instrumentation, read the thread config actually sent to the
app-server, and establish which — do not guess.

**Two traps.**

- **Wildcard `toolsAllow` is the wrong direction.** It makes
  `hasWildcardCodexToolsAllow` true, which *enables* code mode. It would also
  hand a screen-pointing teaching agent every tool on the Gateway. Do not do it.
- **`codeModeOnly: true` is also the wrong direction** — that is
  `features.code_mode_only`, a stricter code mode, not a disable.

What you want is `features.code_mode: false` on the calla thread, reached through
a supported configuration path. Preference order:

1. A documented config key that disables Codex native code mode for one agent.
   Search `docs/` and the `codexAppServer` config schema in
   `dist/config-fy-53tqM.js` before concluding there isn't one.
2. Failing that, make the existing restricted-tool-policy path work as its own
   documentation says it should, in the plugin or via config the plugin sets.
3. Only if neither is reachable: report the gap with the evidence and stop. Do
   not patch files inside `node_modules/openclaw` — it is an npm install and the
   next upgrade silently reverts you.

**Definition of done for this item:** a fresh calla rollout whose tool-call names
include `tutor_observe` / `tutor_guide` / `tutor_plan` as native calls and no
`exec` or `wait` for tutor work, plus a measured per-call cost at or under
~200ms. Prove it with the name histogram, the same way the baseline was taken.

Expect this to also remove two secondary costs, both already measured: 16% of
turns burn a whole model call writing `ALL_TOOLS.filter(/tutor_.../)` just to
discover the tools, and 28% of turns pay an extra `wait` round trip.

## Work item 2 — kill the per-invocation floor

`openclaw agent ...` costs ~10s for a turn that does nothing, of which the
rollout explains 5.2–9.0s and CLI Gateway-connect explains ~2.5s. Every lesson
step pays it, because `apps/tutor/scripts/calla-ask.sh` spawns a fresh
`openclaw agent` per ask over ssh.

Gateway-side, find whether the app-server session can stay warm between steps
instead of being resumed per invocation, and whether there is a persistent
Gateway entry point (a socket, an HTTP route, a long-lived client) that skips the
2.5s connect. Report what the resume actually spends its ~2.7s of setup on —
`calla_step_timing.py` prints it per turn as `setup`.

Do not rewrite `calla-ask.sh` as part of this task; it is Mac-side. Say what it
should call instead and leave it.

## Work item 3 — the two cheap prompt-side wastes

Both are in the plugin, both Gateway-side, both small.

- **Model guesses `session_id`.** In the 12:55 turn it called `tutor_observe`
  with `session_id: "current"`, got a refusal, and retried with
  `"calla-lesson"` — one wasted model call plus one wasted bridged call, ~6s.
  `session_id` is `required` on all ten tools (`src/tools.mjs:11,65,87,129,203,
  234,257,273,294,326,352`) and is model-supplied with `minLength: 8`.
  `src/teaching.mjs:143` only says "keep the same session_id", which does not
  tell it what the first one is. The plugin knows the OpenClaw session; prefer
  resolving `session_id` server-side over asking the model for it. If you make it
  optional in the schema, keep the host-side validation exactly as it is.

- **Capture size is measured but not tunable from here.** Every observe adds
  ~26k input tokens (visible in the rollouts as `15016 → 40476`), and those are
  the calls with the 8.2s and 12.3s waits — image prefill is what makes a model
  call long. The cause is Mac-side: `captureLongEdge = 1600` is persisted in
  `com.calla.tutor-host` and beats the `defaultCaptureLongEdge = 1024` set in
  `TutorSettings.swift:95`, because line 136 reads the stored value first. The
  observe payload has no long-edge parameter, so the Gateway cannot ask for a
  smaller capture. **Report this; do not fix it** — 1600 is a legitimate choice
  in `captureLongEdgeChoices` and may have been picked deliberately. If you think
  the Gateway should be able to request a long edge per observe, propose it as a
  protocol change with the coordinate-guard implications spelled out, and stop.

## Constraints

- **No authority expansion.** The coordinate guard is re-checked independently in
  the tool, the policy hook, and the Mac; the exemption list is exactly `region`
  for `tutor_guide`, `target_hint.region` for `tutor_point`, `steps.<i>.region`
  for `tutor_plan`, and nothing for anything that can act. Keep all three checks
  and all three exemptions unchanged. `tutor_propose_action` and `tutor_verify`
  keep today's rules. If a speed change would widen what Calla can do, stop and
  report instead.
- Do not widen `tools.alsoAllow` for the calla agent.
- Do not edit anything under `node_modules/openclaw`.
- Back up `~/.openclaw/openclaw.json` before each edit and keep the backups
  distinguishable — there are already five `.bak*` files there, do not add to the
  pile ambiguously.
- Tests live at `apps/tutor/integrations/openclaw/test/plugin.test.mjs`. Any
  plugin change ships with a test. Run the existing suite before and after.
- One change at a time, measured independently. Three simultaneous changes cannot
  be attributed, and the baseline above was expensive to get.
- Blender is the only allowlisted application (`org.blenderfoundation.blender`).
  A live end-to-end lesson test needs Blender focused on the Mac and will move
  the cursor overlay on the user's screen. Ask before doing that; the rollout
  histogram and `calla_step_timing.py` prove most of this without it.

## Report back

- The name histogram before and after, so "code mode is gone" is a fact and not
  a claim.
- `calla_step_timing.py` summary before and after: median and p90 turn seconds,
  model calls per turn, bridged-call cost.
- The per-turn split rebuilt after the change: model waits / bridge / setup / Mac.
- Every item you did not do and why, explicitly — especially anything you stopped
  on because it would have widened authority.
