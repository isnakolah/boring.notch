# Sweep integration

Sweep now ships inside `boringNotch.app` as `SweepService.xpc`. The Boring
process remains sandboxed; only the embedded service is unsandboxed, because
surveying user application containers requires Full Disk Access.

## Lifecycle

`Settings → Sweep` creates the XPC connection. No Boring startup path creates
or contacts Sweep service. User may choose whether service stops when leaving
Sweep, when Settings closes, or when Boring quits. Retained service is idle;
survey work begins only when Sweep tab opens, preferences change, or Rescan is
pressed.

## Responsiveness

Sweep scans at utility priority. During a scan, status XPC replies contain only
progress; they never resend survey rows. Cached survey decode also runs off
main actor. Settings uses four tabs: Overview, Clean Up, History, and Options.

Every normal snapshot carries only category rollups (stable category ID, label,
item count, reclaimable bytes) plus protected-item count and size. Clean Up
starts collapsed. Expanding one category requests only that category's first
25 rows; more rows use its continuation offset. A cached page remains readable
while fresh survey replaces its summaries. Protected items use their own
read-only, collapsed group.

Safe targets are preselected, caution targets require selection, and protected
targets cannot be selected. Review cleanup freezes selected targets with saved
or fresh source timestamp; a later survey cannot change pending confirmation.
History loads only when opened. Options uses numeric values with units, path
rows, and explicit service-lifetime descriptions.

## Migration

First Sweep tab open stops running standalone `com.isnakolah.Sweep`, copies
`survey.json`, `history.json`, and `regrowth.json` into
`~/Library/Application Support/boringNotch/Sweep`, imports `sweep.*`
preferences, and writes `migration-v1.json`. Source app, source data, and
source preferences remain untouched as rollback copies.

## Verify

`xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Debug build`
builds and embeds service. `scripts/deploy.sh` verifies app, existing helper,
and Sweep service signatures before installing. Full Disk Access is granted to
the embedded service identity, not old standalone app identity.
