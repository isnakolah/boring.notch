# The intelligence layer

Everything in the app that needs a language model goes through one layer, so a new
feature declares what it wants rather than wiring its own path to a model. The Call
Copilot is its first consumer.

Before this, "intelligence" meant one hard-coded websocket to a Gateway on a
Tailscale host (`wss://nomonhomelab.tailec0dca.ts.net/call-copilot/stream`), with no
picker and no repair path — so an unreachable host meant no suggestions at all.

## Adding a feature that needs a model

Three steps, no new subsystem.

**1. Declare a task.** A task is a feature's identity: what tier of model, what
shape of answer, how long the caller can wait, whether it has a conversation, and
which providers may serve it.

```swift
static let suggest = IntelligenceTask(
    id: "copilot.suggest",                    // dotted, stable, also a Defaults-key suffix
    defaultTier: .balanced,                   // .fast | .balanced | .deep
    contract: .sentinelJSON(keys: ["headline", "angles", "confirm"], marker: "<<<CALLA_END>>>"),
    latencyBudget: 12,
    conversation: .perSession,                // .oneShot | .perSession | .persistent(key:)
    batching: .statement(.call),              // .everyInput | .statement(rules) | .manual
    allowedProviders: [.localAgy]
)
```

**2. Ask.** `IntelligenceRouter.respond(to:)` to await an answer, `enqueue(_:)` to
fire and forget (it coalesces per session), or `stream(_:)` for incremental text.
The router picks a provider, enforces the budget, retries once, falls back, and
reports which brain answered in `response.attribution`.

**3. Add policy only if the feature needs it.** One Defaults key set plus a Settings
row. Core never reads Defaults — policy is passed in as `IntelligenceRouter.Policy`.

### Adding a provider

Conform `IntelligenceProvider` (an actor), declare `supports(_:)` and a
`ModelCatalog`, and register it with the router. Nothing else needs to know.

Note the deliberate asymmetry: **the Gateway is not an `IntelligenceProvider`.** Its
protocol is a push pipe with server-side batching — turns go in, suggestions arrive
unprompted — so wrapping it in `respond(to:)` would invent a request/response
contract it does not have, and could time out while perfectly healthy. Instead
`CopilotAdvisor` owns the one decision that connects the two: whose suggestion the
call publishes. `IntelligenceProvider` is for request/response brains.

### Layout

- `Intelligence/Sources/IntelligenceCore` — pure. Tasks, requests, router,
  `StatementSegmenter`, `PromptComposer`, `ContractParser`, `ModelCatalog`. No
  process, no UI, no Defaults, so it is usable from the app, the XPC engine, and the
  call host alike.
- `Intelligence/Sources/IntelligenceProviders` — `AgyProvider` and its transports.
- A local package rather than files shared by path (the trick the root
  `Package.swift` uses) because SPM refuses a target path outside its package root
  and `CallaCallHost/` is its own package.

## The local provider (`agy`)

Google's Antigravity CLI. Facts below are measured, not assumed; each one is load-bearing.

### Why there is a resident host

Every `agy` process pays **~6-8s of serialized Google round-trips before it answers
anything**: keyring auth, `ListExperiments`, `loadCodeAssist` ×3,
`fetchAvailableModels`. No flag skips it. It is charged per *process*, so the fix is
to stop starting processes.

Each `agy` runs its language server **in-process** on two random localhost ports, and
`agy agentapi` is a client for that server. So one resident host pays the handshake
once, and each request afterwards is:

| Step | Measured |
|---|---|
| `agy agentapi new-conversation --model=flash "<prompt>"` | 0.06s to submit |
| reply readable | ~2.5-3.5s end to end |
| `agy agentapi send-message <cid> "<text>"` | 0.06s to submit |
| a fresh `agy -p` per request, for comparison | ~8.5s |

Replies come back as plain JSONL, not from the TUI and not from protobuf:
`~/.gemini/antigravity-cli/brain/<cid>/.system_generated/logs/transcript.jsonl`, one
object per step; the answer is the next line with `source: "MODEL"`,
`status: "DONE"`. Verified monotonic, with no torn lines.

### Four things that will break it

**1. The host needs a pty.** `agy`'s TUI opens `/dev/tty`, which needs a controlling
terminal, which needs `setsid`; a GUI app has none. Launched directly, the language
server starts, writes its port to the log, and shuts down a moment later when the TUI
fails — and the port line outlives the server just long enough to be read, so every
submit afterwards fails and the provider silently degrades to ~8.5s per request.
Hence `/usr/bin/script`, which supplies both. Its output is never parsed: there is no
ANSI handling anywhere in this provider.

**2. A port is not readiness.** The port appears in ~0.1s, but `new-conversation`
fails with `no available models found` until the server has fetched its model list at
~4.7s. `AgyHost` waits for `v1internal:fetchAvailableModels` in the log —
deliberately the RPC URL, because an earlier line reads `skipping
fetchAvailableModels` and matching that declares readiness ~4s too early.

**3. Kill the tree, not the wrapper.** `Process.terminate()` signals `script`, whose
child is the `agy` holding the server. Signalling only the wrapper orphans a ~190MB
resident process per call — and those orphans keep writing port lines into later
hosts' logs, so a subsequent host reads someone else's port and never works. Each
host also gets its own `run-<pid>-<uuid>` directory for this reason.

**4. `HOME` must come from the passwd database.** `agy` keeps credentials in
`$HOME/.gemini`. The app is sandboxed, so `NSHomeDirectory()` there is the container;
passing that to a child points it at a `.gemini` that does not exist, so it starts a
fresh OAuth flow — while an unsandboxed process reading the real path reports
credentials as present. That combination is what makes Settings say "signed in" while
a call pops a browser demanding sign-in. `AgyEnvironment.userHome` uses `getpwuid`,
which the sandbox does not redirect, so every process agrees.

### Signing in

`agy` has no `login` subcommand; auth is triggered on first use. When stdin is a
terminal and no credentials exist it prints to stderr:

```
Authentication required. Please visit the URL to log in:
  https://accounts.google.com/o/oauth2/auth?...&state=...

Waiting for authentication (timeout 60s)...
Or, paste the authorization code here and press Enter:
```

Both routes work: the hosted callback, and pasting the code. **With stdin as a pipe
it refuses outright** (`Run 'agy' to log in, then retry.`), so the engine runs the
sign-in under a pty, captures that output, publishes the URL
(`CopilotStatus.agyLoginURL`) and the paste prompt (`agyAwaitingCode`), and writes the
pasted code to the pty. A wrong code comes back as
`oauth2: "invalid_grant" "Malformed auth code."` — `CallaAgyLoginParsing` turns that
into something a user can act on, and is pinned by tests against the real strings.

"Sign in again" passes `force`, which moves the existing credential aside
(`oauth_creds.json.superseded`) first — without it, pressing the button when
credentials already exist does nothing, which is useless in exactly the case people
press it.

### Cost discipline

`agy` injects ~14.9k tokens of tool definitions into **every** request and no flag
removes it (`--mode plan` costs +790, `--sandbox` +722, `disabledTools` is MCP-only,
`--agent` is silently ignored). What we control:

- Guidance is sent once per conversation; later turns carry only what is new.
- One request per **statement**, not per transcript turn — see below.
- No `--json-schema`: it works, but spends an extra turn.
- Context is re-sent in full every turn (`cache_read_tokens` is always 0), so a
  session rolls to a fresh conversation past ~45k estimated tokens, seeded with a
  compact brief. This keeps latency flat across a long call, not just cost.
- The host itself makes zero model calls while idle.

## Statement batching

Turns are not sentences. `UtteranceDetector` closes an utterance after 500ms of
silence or a hard 10s cap, so `"so what I'd need from you—"` is a whole turn. Asking
about each one spends ~15k tokens on half a sentence and produces suggestions that
chase fragments.

`StatementSegmenter` buffers per speaker and emits only complete thoughts. Eight
rules, first match wins, all thresholds in `StatementRules`, one test per rule:

1. never flush a turn the VAD chopped at its cap (≥9.5s, gap <0.3s)
2. speaker change flushes the other lane — a completed exchange is the best moment
3. terminal punctuation plus ≥0.7s silence
4. ≥1.5s silence regardless of punctuation (Whisper often drops it), but a hanging
   conjunction waits 2.5s
5. 120 words or 30s force a flush, marked `truncated`
6. 4s idle flushes, so a trailed-off sentence never leaves the copilot silent
7. under 3 words with no `?` is discarded — don't spend a request on "yeah"
8. a 2.5s floor between requests, so a fast exchange becomes one prompt

Expect roughly 2-5 turns per statement; `probe-local` prints the ratio, and a ratio
near 1.0 means the rules are not firing.

## Verifying it

```sh
swift test                                  # validation + login parsing (pure)
cd Intelligence && swift test               # core + providers
cd Intelligence && AGY_LIVE=1 swift test --filter AgyLiveTests   # real agy; spends quota
cd CallaCallHost && swift build && ./.build/debug/CallaCallHost probe-local
```

`probe-local` is the acceptance gate: it replays a canned call and **fails on latency
as well as on error**, because a silent fall back to the print transport looks like
success otherwise. It also prints the segmentation ratio and the last local failure.

After any change here, check for leaks — this should print `0`:

```sh
pgrep -f "agy --log-file" | wc -l
```

## Not yet migrated

`tutor.ask` (`BoringCallaEngineProtocol.swift`) still talks to the Gateway directly.
It is the obvious next consumer: declare the task, route it, keep the Gateway as its
provider.
