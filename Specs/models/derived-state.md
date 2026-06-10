---
id: domain.derived-state
kind: domain
depends-on: [domain.signal, domain.state]
---

# Derived State

`@DerivedState` is a **cached derived value** (a _memo_): a read-only signal whose value is produced by a closure over other signals. It recomputes only when one of the signals it actually read changes, recomputes at most once per change, and — when its recomputed value is unchanged — does not propagate to its own dependents. Realized as a `@propertyWrapper` conforming to `ReadableSignal`.

```swift
@State var count = 0
@DerivedState var doubled = count * 2   // recomputes only when `count` changes
```

## Shape

| Member           | Type                                          | Notes                                                                                                                                                              |
| ---------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| init             | `@autoclosure @escaping () throws -> Wrapped` | The computation. Captured, not run, until first read.                                                                                                              |
| init `equals:`   | `(Wrapped, Wrapped) -> Bool`                  | Optional-to-supply comparator overriding equality-gating (a separate init overload; omit it for the default: `==` when `Wrapped: Equatable`, else always-changed). |
| `wrappedValue`   | `Wrapped`                                     | A tracked read of the cached value; computes it on demand.                                                                                                         |
| `projectedValue` | `Self`                                        | `$derived` — the signal handle.                                                                                                                                    |

The computation is a **throwing autoclosure**: it may read signals and may throw. A read of a derived value is therefore potentially throwing (`try`), and the body runs inside a reactive context so its reads register dependencies.

## Identity

A `DerivedState` instance _is_ its backing reactive node — the cache plus the computation plus the current dependency set.

## Invariants

- **Lazy.** The computation does not run until the value is first read.
- **Cached.** Repeated reads without an intervening dependency change return the cached value without recomputing.
- **Recompute-on-change.** When a tracked dependency changes, the next read recomputes the value. See `behavior.reactive.derivation`.
- **At-most-once.** A single change recomputes the value at most once, regardless of how many dependency paths reach it (glitch-freedom). See `behavior.reactive.glitch-free`.
- **Equality-gated propagation.** If a recompute yields a value _equal_ to the previous one, the derived value's own dependents are not recomputed. Equality is `==` when `Wrapped: Equatable`, the supplied `equals:` comparator when one is given, and otherwise treats every recompute as a change (a non-`Equatable`, un-compared value always propagates). A change that nets to no change (e.g. a source written and then reverted) recomputes nothing observable. See `behavior.reactive.equality-gating`.
- **Dynamic dependencies.** Only the signals read on the latest run are dependencies; a branch not taken contributes none. See `behavior.reactive.dynamic-dependencies`.
- **Error transparency.** If the computation throws, the error rethrows to the reader and the surrounding graph stays consistent — other nodes keep working and the value can recompute successfully once its inputs change. See `behavior.reactive.error-propagation`.

## Relationships

- Conforms to `domain.signal` (`ReadableSignal`).
- Reads `domain.state` and other `domain.derived-state` values to form its dependency set.
- Owned by the enclosing `domain.owner`.

## Lifecycle

- Created from a computation; first read activates it (computes and registers dependencies).
- Re-activates its dependency set on each recompute (dependencies are recomputed dynamically, not fixed at creation).

## Notes

- **Equality-gating compares successive computed values; `Wrapped` need not be `Equatable`.** `DerivedState<Wrapped>` carries no `Wrapped: Equatable` bound. When `Wrapped: Equatable`, a recompute yielding a value `==` the previous one is gated and propagation stops. When `Wrapped` is **not** `Equatable`, the library has nothing to compare with, so every recompute counts as a change and propagates. Either default can be overridden by supplying an `equals:` comparator at construction (`@DerivedState(equals:)`) — which also gives a non-`Equatable` `Wrapped` a way to gate. The `behavior.reactive.equality-gating` scenarios all use `Equatable` value types, so they exercise the default gated path.
- `Sendable`.
- **Writing inside the computation is discouraged.** Assigning a `@State` from inside the computation re-enters the graph mid-propagation; beyond memory safety the result is unspecified, and a write that feeds back into the computation's own inputs is a dependency cycle (see `error.reactive.cycle`). Computations should be pure reads over their inputs.
