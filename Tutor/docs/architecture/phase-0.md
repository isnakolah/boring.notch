# Phase 0 architecture

## Product invariant

Calla Tutor teaches before it acts. The reasoning brain may be local or on infrastructure owned by the user, but only the Mac host can authorize capture, resolve current UI targets, approve consequential actions, dispatch input, and verify results.

## Current component map

```text
User-owned OpenClaw Gateway (Calla gateway role)
  tutor plugin
    tutor_observe / tutor_point / tutor_propose_action / tutor_verify
    no user-identity gate + one-shot action approval
    server-local App Pack retrieval and canonical descriptor index: ~/.openclaw/tutor/{packs,indexes}
                 │
                 │ private-tailnet paired-node invocation
                 ▼
OpenClaw node host on the user's Mac (Calla node role)
  tutor.host
                 │
                 │ owner-only newline-delimited JSON over Unix socket
                 ▼
CallaTutorHost.app
  protocol-v2 request and descriptor validation
  focused-Blender allowlist
  focused-window in-memory JPEG capture (on explicit request only)
  layered pack-authored local resolver
    Accessibility candidates + bounded matchers
    optional read-only bridge evidence
    point-only local geometry search prior
  coordinate-free local resolution receipt + overlay
  local one-shot approval
  Accessibility press + pack-authored detector evaluation
                 │
                 ├── macOS Accessibility
                 └── optional read-only Blender Tutor Bridge
                         ping / observe_state only
```

## Authority boundaries

### Brain

The brain may select a teaching move and request a semantic operation. It cannot issue executable screen coordinates, CGEvents, shell commands, or arbitrary Blender Python. A retrieved target descriptor must be returned verbatim for point, action, and verification requests; the Gateway accepts it only if it is structurally valid and byte-for-byte equivalent to exactly one installed App-Pack entity.

When explicitly asked with `include_capture: true`, the focused allowlisted window is JPEG-encoded in memory and sent over the private tailnet to the user-owned Gateway. It is untrusted, bound to the observation receipt, never persisted, and may produce only a normalized visual search prior for `tutor_point`. The Mac derives all local bounds and action evidence; action requests reject a visual hint unconditionally.

### OpenClaw plugin

The plugin exposes only high-level tutor tools. The private single-user setup
does not require an OpenClaw owner identity, rejects coordinate-shaped
parameters recursively, and asks for an allow-once/deny decision for
`tutor_propose_action`.

This approval is defense in depth, not final authorization.

### Mac TutorHost

TutorHost is the non-delegable trust boundary. It will:

1. require one focused allowlisted window and a protocol-v2 App-Pack descriptor;
2. obtain a fresh observation receipt;
3. resolve through bounded Accessibility candidates and optional read-only bridge evidence;
4. use a visual region only to crop a pointing search and require a unique local result;
5. require the descriptor's authored point/action confidence threshold;
6. show a local highlight and collect one-shot local approval for consequential input;
7. revalidate snapshot/window identity immediately before dispatch;
8. dispatch only the approved Accessibility press; and
9. evaluate the canonical pack-authored detector and return `satisfied`, `unsatisfied`, or `unknown`.

### Blender bridge

The Blender add-on is deliberately narrower than general Blender MCP servers. It binds to loopback, generates a per-launch token, writes the descriptor with owner-only permissions, executes reads on Blender's main thread, limits request/response sizes, and supports only `ping` and `observe_state`.

## App Pack build

Source packs use YAML and Markdown with YAML front matter. `packctl` validates:

- manifest and entity JSON Schemas;
- globally unique stable IDs;
- source/provenance references;
- lesson target, detector, and concept references;
- explicit `ui_target` resolver branches, neighbor constraints, and authored point/action confidence;
- bounded detector provider/query contracts;
- one portable safe-matcher grammar (128-byte patterns; literals, anchors, character classes, and alternation only);
- absence of raw or normalized coordinate-bearing pack fields.

Compilation creates a deterministic-entry `.otpack` ZIP containing:

- `manifest.json`;
- `entities.json`;
- `index.sqlite3`, an FTS5 retrieval index.

Vector search is intentionally deferred until lexical retrieval fails measurable tests.

## What is verified on this Linux host

- Blender App Pack validation, compilation, and FTS retrieval;
- rejection of duplicate IDs, unknown semantic references, unsafe matchers, malformed descriptors, invalid confidence, and coordinate-bearing fields;
- Blender read-only observation contract, token denial, arbitrary-operation denial, loopback server, owner-only descriptor, and main-thread scheduling behavior using a fake Blender runtime;
- OpenClaw plugin registration, canonical descriptor forwarding, capture/hint contract, action-hint denial, approval contract, and bounded Unix-socket transport;
- live isolated OpenClaw runtime inspection of all five tools and the typed `before_tool_call` hook.

## What requires macOS

- `swift test` for TutorKit;
- Accessibility onboarding;
- a real approved click followed by stable verification in Blender 5.2;
- Xcode signing, entitlements, packaging, and notarization decisions.
