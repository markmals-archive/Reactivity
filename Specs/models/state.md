---
id: domain.state
kind: domain
depends-on: [domain.signal]
---

# State

`@State` is the concrete **writable signal**: a piece of mutable reactive state a caller reads, assigns, and observes. It is the source from which `domain.derived-state` values and `domain.observer` effects derive. Realized as a `@propertyWrapper` conforming to `WritableSignal`.

```swift
@State var count = 0
count += 1          // a tracked write — notifies dependents
let now = count     // a tracked read inside a reactive context — registers a dependency
let peeked = $count.peek()  // an untracked read — registers nothing
```

## Shape

| Member           | Type                            | Notes                                                                                                                                                                |
| ---------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wrappedValue`   | `Wrapped`                       | `get` is a tracked read; `nonmutating set` is a write that notifies only when the value changes (see Invariants).                                                    |
| init `equals:`   | `((Wrapped, Wrapped) -> Bool)?` | Optional comparator gating writes. Default: `==` when `Wrapped: Equatable`, else always-notify. Pass `{ _, _ in false }` to always notify (Solid's `equals: false`). |
| `projectedValue` | `Self`                          | `$state` — the signal handle, used for `peek()`.                                                                                                                     |
| `peek()`         | `() -> Wrapped`                 | Reads the current value **without** registering a dependency.                                                                                                        |

The setter is `nonmutating`: assigning through `@State` mutates shared reactive storage, not the wrapper struct. Two reads of the same `@State` see the same storage.

## Identity

A `State` instance _is_ its backing reactive node. Copying the wrapper value shares the node; there is no separate identifier a caller addresses.

## Invariants

- **Tracked read.** Reading `wrappedValue` inside a reactive context registers the reader as a dependent (per `domain.signal`).
- **Notifying write.** Assigning `wrappedValue` a value that differs from the current one updates the stored value and schedules dependents to be re-checked. **Assigning a value _equal_ to the current one is a no-op** — the value is not re-stored and no dependent is notified. Equality is `==` when `Wrapped: Equatable`, the `equals:` comparator when supplied, and otherwise every write notifies (a non-`Equatable`, un-compared value can't be gated). See `behavior.reactive.equality-gating`.
- **Untracked read.** `peek()` returns the current value and registers nothing — even inside a reactive context. See `behavior.reactive.untracking`.
- **Value identity of storage.** Reads observe the latest written value; there is no stale snapshot between a write and the next read.

## Relationships

- Conforms to `domain.signal` (`WritableSignal`, hence `ReadableSignal`).
- Read by `domain.derived-state` and `domain.observer` to form dependencies.

## Lifecycle

- Created with an initial value (`@State var x = …`).
- Owned by the enclosing reactive scope (`domain.owner`); its dependents are released when those dependents are disposed.

## Notes

- `Sendable`.
- **Writing a value equal to the current one is a no-op at the source** (no notification), matching SolidJS 1.x. Solid's `writeSignal` guards its store-and-notify body on `!comparator(current, value)`, so a default signal (comparator `===`) suppresses an equal write — behavior that has held across the entire 1.x line. We gate `@State` writes the same way, reusing the equality policy of `domain.derived-state` (`==` for `Equatable`, an `equals:` comparator otherwise, always-notify when uncompared); Solid's `equals: false` force-notify maps to `equals: { _, _ in false }`. Note the gate is value equality (`==`) here, not Solid's reference `===`. Source-side gating is pinned by `behavior.reactive.equality-gating.equal-write-noop`; the comparator surface by `.custom-comparator` and `.force-notify`.
- **Equality is also storage acceptance.** An assignment gated as equal is rejected entirely: the previously stored instance stays in place (the new, equal-but-distinct instance is discarded) and no dependent is notified. The comparator therefore defines both _observable change_ and _what gets stored_ — an `equals:` that ignores fields the computation reads will hide writes that differ only in those fields. This matches Solid 1.x, where the comparator guards store-and-notify together.
- **Writes are assignments.** Only an assignment through `wrappedValue` is a tracked write. For value-typed `Wrapped`, mutating a member (`state.field = x`) round-trips through the getter and setter and is therefore a write. For reference-typed `Wrapped`, in-place mutation of the instance (`model.value = x` without reassigning the wrapper) never touches the setter and is invisible to the graph — no dependent is notified. Model mutable reference types by giving the class `@State` properties: each property is its own signal, and writes to it propagate normally. See `behavior.reactive.derivation.nested-state`.
- **Writing inside a reactive computation is discouraged.** Assigning a `@State` from inside a `@DerivedState` body (or an effect) re-enters the graph mid-propagation; beyond memory safety the result is unspecified, and a write that feeds back into the writer's own inputs is a dependency cycle (see `error.reactive.cycle`). Perform writes from outside the graph.
