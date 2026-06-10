---
id: behavior.reactive.equality-gating
kind: behavior
depends-on: [domain.derived-state, domain.signal]
---

# Equality-gated propagation

Propagation stops at a value whose recomputed result is unchanged: an input that recomputes to an equal value does not cascade, and a value recomputes only when at least one of its inputs actually changed.

## Scenarios

### Background

- Given derived values that depend on one or more inputs
- And a count of how many times each value recomputes

### Scenario 1: An unchanged recomputed value does not cascade

<!-- id: behavior.reactive.equality-gating.unchanged-bails-out -->

- Given a derived value that reads a source but always recomputes to the same result
- And a downstream value derived from it
- When the source changes
- Then the upstream value recomputes but yields its previous result
- And the downstream value does not recompute

### Scenario 2: Reverting a source back to its previous value triggers no recompute

<!-- id: behavior.reactive.equality-gating.reverted-source -->

- Given a derived value computed once from a source
- When the developer changes the source and then changes it back to its previous value
- Then the derived value does not recompute

### Scenario 3: A value recomputes when one of several inputs changed

<!-- id: behavior.reactive.equality-gating.one-of-many-changed -->

- Given a value derived from two inputs of a shared source, one that reflects the source and one that always recomputes to the same result
- When the source changes
- Then the value recomputes exactly once
- And it yields a result reflecting the changed input

### Scenario 4: A changed input wins over unchanged sibling inputs

<!-- id: behavior.reactive.equality-gating.changed-sibling -->

- Given a value derived from three inputs of a shared source, one that reflects the source and two that always recompute to the same result
- When the source changes
- Then the value recomputes exactly once
- And it yields a result reflecting the changed input

### Scenario 5: A value with only unchanged inputs does not recompute

<!-- id: behavior.reactive.equality-gating.all-unchanged -->

- Given a value derived from two inputs of a shared source that both always recompute to the same result
- When the source changes
- Then the value does not recompute

### Scenario 6: A value reaching a source two ways still settles correctly

<!-- id: behavior.reactive.equality-gating.indirect-check -->

- Given a value that reads a source directly and also through an intermediate derived value that always recomputes to the same result
- When the source changes
- Then the value settles to the source's new value, even though the intermediate looks unchanged

### Scenario 7: Writing an equal value to a source notifies nothing

<!-- id: behavior.reactive.equality-gating.equal-write-noop -->

- Given a derived value computed once from a source
- When the developer assigns the source a value equal to its current one
- Then reading the derived value yields the previous result without recomputing

### Scenario 8: A custom comparator gates a source write

<!-- id: behavior.reactive.equality-gating.custom-comparator -->

- Given a source created with a comparator that treats two distinct values as equal
- And a derived value computed once from that source
- When the developer assigns the source the other of those two values
- Then reading the derived value yields the previous result without recomputing

### Scenario 9: An always-unequal comparator forces propagation

<!-- id: behavior.reactive.equality-gating.force-notify -->

- Given a source created with a comparator that never treats two values as equal
- And a derived value computed once from that source
- When the developer assigns the source its current value
- Then reading the derived value triggers exactly one recompute

### Scenario 10: A derived comparator gates downstream propagation

<!-- id: behavior.reactive.equality-gating.derived-custom-comparator -->

- Given a derived value created with a comparator that treats its recomputed results as equal
- And a downstream value derived from it
- When the source changes
- Then the upstream value recomputes
- And the downstream value does not recompute
