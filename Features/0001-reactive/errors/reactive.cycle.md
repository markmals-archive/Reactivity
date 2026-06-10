---
id: error.reactive.cycle
kind: error
depends-on: [domain.signal, domain.derived-state]
---

# Dependency cycle in a reactive computation

The "user" here is a developer using the reactive API. A computation that reads a value whose evaluation is already in progress on the current task — directly, or through any chain of intermediates — has formed a dependency cycle. A cycle has no well-defined settled value, so it is a programming error, not a recoverable condition: the library traps deterministically at the read that closes the cycle.

## When this happens

A `@DerivedState` computation reads its own value, or reads another derived value whose evaluation is already in progress on the same task's computation chain (mutual or longer cycles). Re-entrant evaluation on a _different_ task is not a cycle — it is concurrent use, covered by the concurrency model.

## What the developer sees

The process traps (`preconditionFailure`) at the moment the cycle closes, with a diagnostic naming the condition:

> "ReactiveGraph: dependency cycle detected — a computation read a value whose evaluation is already in progress on this task."

The trap is deterministic: the same graph and the same read always trap at the same point, on first evaluation — cycles cannot lie dormant past their first read.

## What the developer can do

- Restructure the graph so the value no longer (transitively) depends on itself — usually by splitting the cyclic computation into two values with a one-directional dependency.
- Hoist the offending read out of the computation: read the value before constructing the derived state and capture the result.

## Scenarios

### Scenario 1: A self-referential derived value traps

<!-- id: error.reactive.cycle.self-read -->

- Given a derived value whose computation reads its own value
- When the developer reads it
- Then the process traps with a cycle diagnostic

### Scenario 2: Mutually dependent derived values trap

<!-- id: error.reactive.cycle.mutual -->

- Given two derived values whose computations each read the other
- When the developer reads either one
- Then the process traps with a cycle diagnostic

## Underlying cause (informational)

- A tracked read reaches a value whose computation appears in the current task's chain of in-progress computations. Detection walks that chain (it is as deep as computation nesting, not graph size); the trapping site carries this spec's reverse pointer.
- A write into the writer's own inputs from inside a computation is the write-side route into the same condition; see the warnings in `domain.state` and `domain.derived-state`.

## Related

- `domain.derived-state` — the computation whose re-entrant evaluation is the cycle.
- `domain.signal` — the reactive context whose chain of in-progress computations makes detection possible.
- `behavior.reactive.error-propagation` — thrown errors are recoverable and rethrow; a cycle is not an `Error`, it traps.
