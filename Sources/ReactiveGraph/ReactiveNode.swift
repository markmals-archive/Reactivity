// SPEC: domain.signal
// SPEC: domain.state
// SPEC: domain.derived-state
// SPEC: behavior.reactive.derivation

import Synchronization

// MARK: - Node state

/// The three-state coloring used by the lazy pull-based graph.
///
/// - `clean`: value is up-to-date.
/// - `check`: a transitive dependency may have changed; re-validate sources before deciding.
/// - `dirty`: a direct dependency definitely changed; recompute on next read.
enum NodeState {
    case clean
    case check
    case dirty
}

// MARK: - Type-erased node handle

/// Type-erased handle to a reactive node used for edge storage.
///
/// Identity is based on the underlying `ReactiveNode` object so handles can be
/// matched when rebuilding observer lists after a recompute.
// SPEC: manual — edge handle; purely internal graph plumbing.
final class AnyReactiveNode: @unchecked Sendable {
    // @unchecked Sendable: the handle itself is immutable after init;
    // the underlying node guards its own mutable state.

    /// Stable identity derived from the underlying node object.
    let identity: ObjectIdentifier

    private let _updateIfNecessary: () -> Void
    private let _removeObserver: (ObjectIdentifier) -> Void
    private let _invalidate: (NodeState) -> Void

    init<W>(node: ReactiveNode<W>) {
        identity = ObjectIdentifier(node)
        _updateIfNecessary = { node.updateIfNecessary() }
        _removeObserver = { id in node.removeObserver(identity: id) }
        _invalidate = { state in node.invalidate(state) }
    }

    /// Ensures the node's value is current.
    func updateIfNecessary() { _updateIfNecessary() }

    /// Removes the observer with the given identity from this node's observer list.
    func removeObserver(identity id: ObjectIdentifier) { _removeObserver(id) }

    /// Marks this node with `state` and propagates downstream.
    func invalidate(_ state: NodeState) { _invalidate(state) }
}

// MARK: - ReactiveNode

/// The backing storage for both `State` (source node) and `DerivedState` (derived node).
///
/// Source nodes have no computation; their value is written directly via `write(_:)`.
/// Derived nodes hold a computation closure and use three-state lazy evaluation:
/// they recompute only when read, and only when their state is not `.clean`.
///
/// All mutable fields are `nonisolated(unsafe)` and serialized by `lock`.
// SPEC: behavior.reactive.derivation — the mark-dirty write path and the
// updateIfNecessary pull path together implement recompute-on-change propagation.
final class ReactiveNode<Wrapped>: @unchecked Sendable {
    // @unchecked Sendable: every access to mutable state below is serialized
    // by `lock`. `body` and `isEqual` are set at init and never mutated.

    // MARK: Lock
    // SPEC: manual — Mutex<Void> used as a plain binary lock. All reads and
    // writes of the fields below must occur inside `lock.withLock { }`.
    // `body` closures and recursive calls (updateIfNecessary on sources) run
    // OUTSIDE the lock to prevent deadlock on re-entrant reads — callers
    // snapshot what they need, unlock, do the work, then re-lock to commit.
    private let lock = Mutex<Void>(())

    // MARK: Mutable state (guarded by lock)
    private nonisolated(unsafe) var cachedValue: Wrapped?
    private nonisolated(unsafe) var state: NodeState
    private nonisolated(unsafe) var sources: [AnyReactiveNode] = []
    private nonisolated(unsafe) var observers: [AnyReactiveNode] = []

    // MARK: Immutable state (set at init, never mutated)

    /// The computation that produces this node's value, or `nil` for source nodes.
    private let body: (() throws -> Wrapped)?

    /// Equality test: returns `true` when two values should be treated as unchanged.
    private let isEqual: (Wrapped, Wrapped) -> Bool

    // MARK: Init — source node (State)

    /// Creates a source node with an initial value and an equality policy.
    init(value: Wrapped, isEqual: @escaping (Wrapped, Wrapped) -> Bool) {
        cachedValue = value
        state = .clean
        body = nil
        self.isEqual = isEqual
    }

    // MARK: Init — derived node (DerivedState)

    /// Creates a derived node whose value is produced lazily by `body`.
    /// The body is not called until the first read (lazy invariant).
    init(body: @escaping () throws -> Wrapped, isEqual: @escaping (Wrapped, Wrapped) -> Bool) {
        cachedValue = nil
        state = .dirty  // dirty so the first read triggers a compute
        self.body = body
        self.isEqual = isEqual
    }

    // MARK: Read (tracked)

    /// Returns the current value, registering a dependency edge when called
    /// from inside a reactive computation.
    func read() -> Wrapped {
        updateIfNecessary()
        // Register bidirectional edge when called from inside a reactive computation:
        //   source.observers  += handle-to-observer  (so source can notify observer)
        //   frame.sources     += handle-to-self      (so observer can re-validate self)
        if let frame = ReactiveContextKey.current {
            // Deduplicate before allocating the handle: repeat reads of the same
            // source within one run are the common case on this hot path.
            if !frame.isTracked(ObjectIdentifier(self)) {
                lock.withLock { _ in observers.append(frame.observer) }
                frame.track(AnyReactiveNode(node: self))
            }
        }
        return lock.withLock { _ in cachedValue! }
    }

    // MARK: Write (State only)

    /// Stores a new value and notifies observers.
    ///
    /// An equal value is a no-op: not stored and no dependent is notified
    /// (equality-gated write invariant from `domain.state`).
    func write(_ newValue: Wrapped) {
        let snapshot: [AnyReactiveNode]? = lock.withLock { _ in
            if let current = cachedValue, isEqual(current, newValue) { return nil }
            cachedValue = newValue
            return observers
        }
        guard let obs = snapshot else { return }
        for observer in obs {
            observer.invalidate(.dirty)
        }
    }

    // MARK: Propagation

    /// Marks this node with `newState` (if it is a strict upgrade) and propagates
    /// `.check` to downstream observers.
    // SPEC: behavior.reactive.derivation — write path: marks this node dirty/check,
    // then propagates check transitively so downstream nodes know to re-validate.
    func invalidate(_ newState: NodeState) {
        let snapshot: [AnyReactiveNode]? = lock.withLock { _ in
            guard upgrade(&state, to: newState) else { return nil }
            return observers
        }
        guard let obs = snapshot else { return }
        for observer in obs {
            observer.invalidate(.check)
        }
    }

    // MARK: Pull / updateIfNecessary

    /// Ensures this node's cached value is current.
    // SPEC: behavior.reactive.derivation — pull path: validates sources and recomputes
    // lazily, ensuring a read always reflects the latest inputs through chains of
    // derivations and across multiple paths to the same source.
    func updateIfNecessary() {
        let currentState = lock.withLock { _ in state }
        switch currentState {
        case .clean:
            return

        case .check:
            // Validate each source in read order. After each source validates itself,
            // re-read OWN state: a source's recompute may have pushed `.dirty` onto
            // this node (via the invalidate path) while we were mid-loop. If that
            // happened, stop early and recompute — trusting the pushed state rather
            // than the consumed per-call boolean that the first caller already drained.
            let currentSources = lock.withLock { _ in sources }
            for source in currentSources {
                source.updateIfNecessary()
                // Re-read own state: did a source's recompute escalate us to dirty?
                let ownState = lock.withLock { _ in state }
                if ownState == .dirty {
                    recompute()
                    return
                }
            }
            // No source escalated us. Settle to clean only if we are still in .check
            // (a concurrent write could have upgraded us to .dirty; don't clobber it).
            lock.withLock { _ in
                if state == .check { state = .clean }
            }

        case .dirty:
            recompute()
        }
    }

    // MARK: Internal edge management

    /// Removes the observer whose underlying node has the given identity.
    func removeObserver(identity: ObjectIdentifier) {
        lock.withLock { _ in observers.removeAll { $0.identity == identity } }
    }

    // MARK: Recompute

    /// Runs the computation, re-collects dependency edges, and notifies observers
    /// if the new value differs from the cached value per the equality policy.
    private func recompute() {
        guard let body else { return }

        // Build the observer handle for this node (used by sources to notify us).
        let myHandle = AnyReactiveNode(node: self)

        // Detach this node from all current sources (dynamic dep re-collection).
        let oldSources = lock.withLock { _ -> [AnyReactiveNode] in
            let old = sources
            sources = []
            return old
        }
        for source in oldSources {
            source.removeObserver(identity: myHandle.identity)
        }

        // Run the body inside a fresh tracking frame that carries our observer handle.
        let frame = ReactiveFrame(observer: myHandle)
        let newValue: Wrapped
        do {
            newValue = try ReactiveContextKey.$current.withValue(frame) {
                try body()
            }
        } catch {
            // SPEC: domain.derived-state — error propagation is a later spec.
            preconditionFailure(
                "DerivedState computation threw: \(error). "
                    + "Error propagation is not yet implemented "
                    + "(see behavior.reactive.error-propagation)."
            )
        }

        // Commit: wire up fresh source edges and update cached value.
        let changed: Bool = lock.withLock { _ in
            sources = frame.sources
            let didChange: Bool
            if let old = cachedValue {
                didChange = !isEqual(old, newValue)
            } else {
                didChange = true  // first compute always counts as changed
            }
            cachedValue = newValue
            state = .clean
            return didChange
        }

        // If the value changed, notify our own observers so that any downstream
        // nodes that are in `.check` state (but were not the caller of this
        // updateIfNecessary) are escalated to `.dirty` and will recompute on
        // their next read rather than returning a stale cached value.
        if changed {
            let obs = lock.withLock { _ in observers }
            for observer in obs {
                observer.invalidate(.dirty)
            }
        }
    }

    // MARK: Helpers

    /// Upgrades `state` to `newState` if it is strictly higher
    /// (`dirty` > `check` > `clean`). Returns `true` when the state changed.
    private func upgrade(_ state: inout NodeState, to newState: NodeState) -> Bool {
        switch (state, newState) {
        case (_, .dirty) where state != .dirty:
            state = .dirty
            return true
        case (.clean, .check):
            state = .check
            return true
        default:
            return false
        }
    }
}
