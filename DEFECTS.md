# Defects

> Sub-spec rough edges. Append on observation; delete on fix. This file should want to be empty.
>
> What belongs here: known rough edges with no observable behavioral contract — a not-yet-fixed internal quirk, a Swift-toolchain-version wrinkle, an acceptable trade-off. If an entry turns out to describe behavior the spec _should_ cover, promote it to a spec amendment via the `triaging-defects` skill and delete the entry.
>
> What does NOT belong here: spec gaps (use `[NEEDS CLARIFICATION]` during authoring, or amend the spec), spec/impl drift (use `/sdd-drift`), or open questions about intent (those go in the spec).

## Open

<!-- Entries land here. Each entry follows this shape:

### <short imperative title>
- observed: <YYYY-MM-DD>
- where: <file:line in Sources/, e.g. Sources/ReactiveGraph/Graph.swift>
- symptom: <one sentence — what's observed>
- repro: <minimal steps, ideally a small Swift snippet or failing test>
- notes: <optional — hypothesis, related spec id, anything useful>

When you fix an entry, delete it. The fix commit is the durable record.
-->

- Don't add status fields, severity labels, or assignees. If an entry needs more structure than the shape above, it's probably a spec change, not a defect.

### Concurrent write during recompute is lost, leaving a stale clean cache

- observed: 2026-06-10
- where: Sources/ReactiveGraph/ReactiveNode.swift (`invalidate(_:)` upgrade no-op + `recompute()` commit)
- symptom: A write to a tracked source that lands while a dependent derived is mid-recompute is swallowed — the derived is already `.dirty`, so `invalidate(.dirty)` no-ops, then the commit stores the pre-write result with `.clean`; later reads return the stale value until the source changes again.
- repro: Task A reads a derived whose body reads `@State s` then blocks; task B sets `s`; A's recompute commits; reading the derived now yields the pre-write value with no pending invalidation. Single-task variant: a derived body that writes its own tracked source after reading it (an unspecced write-inside-computation cycle).
- notes: Found by adversarial review (Codex) of behavior.reactive.derivation. No spec defines linearization for writes racing a recompute. Likely promote-to-spec (concurrency behavior) rather than fix-in-place. Related: domain.signal, behavior.reactive.derivation.
