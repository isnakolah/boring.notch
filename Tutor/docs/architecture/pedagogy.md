# Calla pedagogy contract

Calla treats every request about software as teaching. The single Calla agent
chooses language, route, and visual guidance; deterministic plugin and Mac
state gate attempts, assistance, verification, and retention. There is no
second classifier, evaluator, or pedagogy model.

## Invariants

- `PED-1` — observe a focused, allowlisted application before procedural
  instruction. If none is teachable, ask once for the application rather than
  guessing or writing a recipe.
- `PED-2` — retrieve a matching installed App Pack when one exists; preserve
  its target and detector descriptors unchanged.
- `PED-3` — use the least assistance that can teach: explain, highlight,
  point, then bounded approved assistance. A failed step holds its index.
- `PED-4` — the final planned step is transfer and the prior planned step is
  assessment. A due review is a retention item at the explain ceiling.
- `PED-5` — pedagogy adds no model-visible calls beyond the current
  **Did it → observe → guide/narrate** flow. Completion verification is a
  single internal Mac IPC, capped at two seconds; missing detectors, errors,
  and timeouts are `unknown`.
- `PED-6` — learning records and evidence are owner-only, atomic, capture-free,
  and never contain titles, paths, OCR, screenshots, or transcripts.

## Prompt budget

The cacheable Calla teaching contract is under 1,600 words. Dynamic lesson
state follows it as a compact delta. Do not add a second static loop, repeated
phrases, or App-Pack text to the cached prefix.

## App-Pack requirements

Every lesson declares `objective.given`, `objective.behavior`, and
`objective.criterion`; misconceptions; assessment; transfer with
`transfer.differs_by`; and retention. Every scored item has canonical
`pass.target` and `pass.detector`. The compiler rejects omissions and invalid
references. Pack-authored targets remain semantic descriptors; coordinate data
never authorizes a visual or consequential action.

## State, verification, and telemetry

Gateway pedagogy state is an in-memory 32-session LRU: selected lesson, plan,
step, attempts, phase, verdict, review status, and bounded deltas. `tutor_plan`
may carry `lesson_id` only when that lesson was retrieved in the same session.
On **Did it**, TutorHost records the feedback-start timestamp, verifies the
current scored detector internally, and returns pass/fail/unknown with the
verification duration on the next observation. Feedback dispatch adds the
end-to-end latency asynchronously to `audit/pedagogy.jsonl`.

`record_learning` is internal-only: it atomically persists only lesson,
learner, success, interval, and due-review metadata on the Mac. The offline
dashboard reads JSONL locally and reports first independent success plus median
completion-to-feedback latency. Neither write may delay learner feedback.

## Boring Engine authority

When `runtimeMode=engine`, this legacy Gateway pedagogy loop is not authority.
BoringCallaEngine owns course/run state, exact revision pinning, durable history,
provider selection, feedback cancellation and deterministic advancement. Host is
limited to authored instruction/overlay, bounded observation, deterministic
detectors and exact target-window capture. Gateway feedback and local `agy` are
tool-free supplemental text providers only. A clean deterministic pass never
waits for a model; fail/unknown feedback never advances a step.
