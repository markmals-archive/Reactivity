---
id: domain.owner
kind: domain
depends-on: []
---

# Owner

An **owner** is a node in the ownership tree that governs the _lifetime_ of the reactive work created inside it. Every signal, derived value, and observer is created under some owner; disposing an owner disposes everything it owns. `withReactiveScope` establishes a root owner; `onCleanup` registers teardown; `Dispose` is the disposer a scope can hand back.

```swift
withReactiveScope { dispose in
    observe { … }                 // owned by this scope
    onCleanup { print("torn down") }
    dispose()                     // disposes the scope: children first, then cleanups
}
```

## Shape

| Member              | Type                                                   | Notes                                                                                                                                               |
| ------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `withReactiveScope` | `((@escaping Dispose) -> T) -> T` and `(() -> T) -> T` | Run `body` under a fresh root owner. The `dispose`-taking form hands the disposer to the body. Sync, `async`, `throws`, `async throws` forms exist. |
| `onCleanup(_:)`     | `(@escaping () -> Void) -> Void`                       | Register a callback on the current owner. Sync and `async` forms.                                                                                   |
| `Dispose`           | `() -> Void`                                           | The disposer closure for a scope.                                                                                                                   |

## Identity

An owner _is_ its node in the tree: its set of owned children (signals, derived values, observers, nested owners) and its registered cleanups.

## Invariants

- **Containment.** Reactive work created while an owner is current is owned by it.
- **Children before self.** Disposing an owner disposes its children first, then runs the owner's own cleanups. See `behavior.reactive.cleanup` and `behavior.reactive.nested-effects`.
- **Cleanup on re-run and on dispose.** A cleanup registered inside an observer runs before that observer's next run, and again if the owner is disposed. A cleanup registered in a `withReactiveScope` body runs when that scope is disposed. Multiple cleanups on one owner run **last-registered-first (LIFO)**. See `behavior.reactive.cleanup`.
- **Idempotent disposal.** Disposing an already-disposed owner does nothing further.
- **Scope value.** `withReactiveScope` returns the value its body returns and rethrows what its body throws.

## Relationships

- Parents `domain.observer` nodes and other owners; nested observers form the child relationships in `behavior.reactive.nested-effects`.
- The cleanup affordance is the teardown half of `domain.observer`'s lifecycle.

## Lifecycle

- **Open** — current; new reactive work attaches to it.
- **Disposed** — torn down (children first, then cleanups); attaching more work to it is not expected after disposal.

## Notes

- **Same-owner cleanup order is LIFO**, chosen to match SolidJS 1.x. Solid's `cleanNode` appends each cleanup (`Owner.cleanups.push(fn)`) and runs them in reverse (`for i = count − 1 … 0`), so the last-registered runs first — conventional resource-unwinding order, where a cleanup may safely depend on setup an earlier-registered cleanup performed. Solid adopted this at v1.7.0 (earlier 1.x ran them FIFO); we match current 1.x. Neither Solid's suite nor ours pins this yet, so `behavior.reactive.cleanup` should gain a scenario for it before `/sdd-apply`.
- `Dispose` is `Sendable` by virtue of being a plain closure type alias; effect teardown may be scheduled rather than synchronous (the async `Clean an effect` scenario yields to the scheduler before observing teardown). See `behavior.reactive.cleanup`.
