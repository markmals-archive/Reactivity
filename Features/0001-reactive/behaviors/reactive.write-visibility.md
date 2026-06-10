---
id: behavior.reactive.write-visibility
kind: behavior
depends-on: [domain.signal, domain.state, domain.derived-state]
---

# Completed writes are never lost

Once an assignment to a source returns, any subsequent read of a dependent value reflects that write or a later one — even when the write lands while the dependent is mid-recomputation. A recomputation that overlaps a write may itself yield a result computed from the pre-write value, but completing it must not erase the pending invalidation: the next read re-validates and catches up.

## Scenarios

### Scenario 1: A write landing during recomputation is not lost

<!-- id: behavior.reactive.write-visibility.write-during-recompute -->

- Given a derived value whose computation writes a new value to its own source after reading it
- And the derived value has been read once, yielding a result computed from the pre-write value
- When the developer reads it again
- Then the read yields a result computed from the written value

### Scenario 2: Concurrent writers converge

<!-- id: behavior.reactive.write-visibility.concurrent-writers -->

- Given a derived value over a source being written from many concurrent tasks
- When every write has completed
- Then reading the derived value yields a result computed from the source's final value

### Scenario 3: Reads under write contention complete and converge

<!-- id: behavior.reactive.write-visibility.reads-under-contention -->

- Given derived values read repeatedly from many tasks while their sources are written from other tasks
- When every task has completed
- Then every read completed without stalling
- And reading each derived value yields a result computed from its sources' final values

### Scenario 4: A diamond settles consistently under contention

<!-- id: behavior.reactive.write-visibility.diamond-under-contention -->

- Given a value derived from a single source along two paths, with concurrent writers and readers
- When every task has completed
- Then reading the value yields a result computed from the source's final value along both paths
