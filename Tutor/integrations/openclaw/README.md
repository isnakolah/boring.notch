# Calla OpenClaw integration

The plugin identifier is `tutor`; Calla remains the user-facing teaching agent. It never exposes raw coordinates, shell execution, CGEvent, or arbitrary Blender code.

## Roles

| Role | Runs on | Registers |
| --- | --- | --- |
| `gateway` | Existing user-owned OpenClaw Gateway | `tutor_*` tools, local action policy, paired-node invocation, server-local retrieval |
| `node` | Paired macOS OpenClaw node | Only `tutor.host`, forwarding validated envelopes to local TutorHost |
| `both` | Development only | Both surfaces; requires `developmentMode: true` |

The Gateway invokes `tutor.host` on the node enrolled by the bundled
private-Tailscale setup. The node handler forwards one validated
newline-delimited JSON envelope to TutorHost's mode-`0600` Unix socket. Until
TutorHost is running it returns the typed result `TUTOR_HOST_UNAVAILABLE`.

Gateway configuration is additive:

```json5
{
  plugins: {
    entries: {
      "tutor": {
        enabled: true,
        config: {
          role: "gateway",
          stateDirectory: "~/.openclaw/tutor",
          nodeId: "AUTO_ENROLLED_CALLA_MAC_NODE_ID",
          requireOwnerIdentity: false,
        },
      },
    },
  },
  gateway: {
    mode: "local",
    bind: "loopback",
    auth: { mode: "none" },
    tailscale: { mode: "off" },
  },
}
```

`scripts/setup-calla-server.sh` adds the private Tailscale HTTPS proxy outside
the Gateway, because the Gateway itself remains loopback-bound. Use
`role: "node"` on the Mac. It must not register Gateway tools.

## Teaching-agent latency policy

The additive server installer creates an isolated `calla` agent and leaves the
Gateway's global agent defaults unchanged. Its configuration is intentionally
narrow:

- `thinkingDefault: "adaptive"` only when the installer verifies the configured
  provider exposes adaptive thinking; otherwise it retains `low` and records
  the fallback. The Mac launcher does not override that decision per turn.
- `params.cacheRetention: "long"`, which lets OpenClaw reuse the stable
  teaching prompt, plugin schemas, and tool definitions across a lesson.
- the `minimal` tool profile plus exactly Calla's eight `tutor_*` tools, keeping
  unrelated coding, messaging, and browser schemas out of the teaching prompt.

The launcher sends to this agent explicitly (`openclaw agent --agent calla`).
`fastMode: "auto"` is deliberately not enabled by the installer: it is a
priority-processing experiment with a billing tradeoff, and the current
`openclaw agent` CLI has no one-turn fast-mode flag. Test it through a
`chat.send` caller before opting it into this path.

Calla has `skills: []` and `memorySearch.enabled: false`: its teaching prompt
does not inherit general-agent skills, workspace memory, or transcript recall.
The Tutor plugin injects only its stable teaching contract, the active lesson
state, exact installed App-Pack descriptors, and a small Calla-only memory block.

## Lesson state and Calla memory

The Gateway writes one short-lived `lessons/*.json` record per lesson under the
configured Tutor state directory. It has the stable lesson/cache identity,
allowed application/version, pack revision, plan count/current step, and a
non-reversible snapshot fingerprint. It never contains capture bytes, window
or document titles, paths, regions, guide text, or a transcript; it is removed
at lesson end or after 30 minutes idle.

`calla-memory/facts.sqlite` is a separate SQLite/FTS store, never the main
agent graph. It keeps only sanitized learner preferences, versioned App-Pack
facts, and verified teaching patterns. Facts expire after 90 days; recall is
bounded to six facts and 1,200 characters. The plugin supplies matching pack
descriptors with the initial observation, so a model does not spend a separate
turn calling retrieval for ordinary UI targets.

Normal lessons take one initial focused-window image. Planned steps advance on
the Mac without model calls and `tutor_guide` forcibly disables post-guide
capture. A mismatch gets one tight crop; a new full image is reserved for
focus, application, or plan-identity failure. The usage hook records recovery
state before compaction and rehydrates it in the same logical lesson session.

## Server-local App Pack retrieval

`tutor_retrieve` runs on the Gateway; it does not round-trip to the Mac. It requires the active application bundle ID and version, then filters packs by their `apps` compatibility constraints and entities by optional `app_versions`.

Install a compiled App Pack into the user-owned server state:

```bash
python3 tools/calla_pack_store.py build/packs/blender.otpack \
  --state-directory ~/.openclaw/tutor
```

This copies the `.otpack` and writes a mode-`0600` JSON retrieval sidecar under `packs/` and `indexes/`. It does not create a network registry or copy the pack to the Mac.

## Verification

```bash
cd integrations/openclaw
npm test
```

The tests prove role isolation, server-local version-filtered retrieval,
coordinate rejection, local one-shot approval, socket transport, and typed
TutorHost unavailability.
