# Security policy

Calla Tutor is pre-release software and must not yet be used to control sensitive or production applications.

## Non-negotiable design rules

- No model-facing raw coordinate, CGEvent, shell, or arbitrary code tool.
- Screen pixels, OCR text, application documents, App Packs, and model output are untrusted.
- The Mac host makes the final authorization decision and fails closed on stale, ambiguous, or unknown state.
- Consequential input requires exact window identity, a fresh semantic target receipt, an authored expected state, and local approval.
- Secure input, authentication, purchases, destructive operations, external submissions, and terminal/code execution prohibit mutations.
- A capture may cross the private tailnet only after an explicit `tutor_observe(include_capture: true)` request. It contains a JPEG of the one focused allowlisted window, is in-memory only, is bound to that observation's snapshot receipt, and is never written by TutorHost or the Calla plugin.
- The Gateway and all model output treat that JPEG as untrusted input. Vision may return only a bounded normalized region used as a local pointing search prior; it never supplies target identity, coordinates, action authority, or post-action verification.
- TutorHost never falls back from a focused-window capture to a display capture. Capture failure, over-size data, stale snapshots, changed windows, ambiguous local results, malformed descriptors, and protocol-version mismatch fail closed.

## Reporting

Do not open a public issue containing screenshots, tokens, private application data, or exploit details. Until a dedicated security address is published, open a minimal issue requesting a private reporting channel without including the sensitive details.
