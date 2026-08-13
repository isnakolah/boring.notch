# Calla Tutor operational context

Calla Tutor is the `tutor` capability. **Calla** is its only teaching agent,
and **Calla Mac** / **Calla TutorHost.app** are the product-facing Mac names.
Keep the `tutor_*` tool names unchanged. `desktop-tutor` is a retired migration
identifier, never a path or command for new work.

[runtime-flow.md](runtime-flow.md) carries the operational detail behind this:
paths, config keys, the call chain, verification commands, and known failures.

## Topology and authority

The loopback-bound OpenClaw Gateway loads only
`apps/tutor/integrations/openclaw`. Tailscale Serve is the private external
route to the paired Mac; never expose the Gateway, OpenClaw, bridge, socket, or
screenshot credentials publicly. The Gateway/Calla agent chooses a semantic
teaching move. Calla Mac's node forwards only `tutor.host` to the local,
owner-only TutorHost socket. The Mac owns focused-window capture, target
resolution, overlays, Screen Recording and Accessibility permissions, local
approval, input dispatch, and verification. It is transport and trust boundary,
not a second language agent.

## Teaching loop

Calla begins with `tutor_observe` using `include_capture: true` and the allowed
bundle IDs, reads the focused-window image, then calls `tutor_guide` with one
tight normalized region and short instruction. The guide waits for the learner
and returns `next_observation`; later steps use that fresh observation. Calla
points and narrates through tools, never writes a chat recipe or clicks. If
capture/observation fails, state the failure briefly and stop.

## Ownership and changes

The plugin state is `~/.openclaw/tutor`; packs and indexes live there and are
Gateway-local. The Calla agent workspace is
`/srv/app/.openclaw/apps/tutor/agent-workspace`. Managed non-secret OpenClaw
policy is in `/srv/app/.openclaw/config/openclaw/`. Use `make tutor` for local
build, test, validation, and status. Run `make openclaw tutor-migrate` only for
the one owned legacy migration; it fails closed for any unexpected Calla
workspace and writes private backups before removing old configuration.

## Verification boundary

Linux tests prove source contracts, config shape, and private-Tailscale setup
logic. They do not prove the Mac. Before claiming the user path works, the Mac
must pull the Tutor update, run
`./scripts/bootstrap-calla-mac.sh --install --yes` over the private tailnet,
re-approve Screen Recording after the rebuilt app, and complete a real TutorHost teaching round trip. Do not run that Mac command from the Gateway or
replace it with Gateway SSH proof.
