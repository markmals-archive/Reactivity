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
/// - `dirty`: value has never been computed (initial state for derived nodes).
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
    private let _invalidateCheck: () -> Void

    init<W>(node: ReactiveNode<W>) {
        identity = ObjectIdentifier(node)
        _updateIfNecessary = { node.updateIfNecessary() }
        _removeObserver = { id in node.removeObserver(identity: id) }
        _invalidateCheck = { node.invalidateCheck() }
    }

    /// Ensures the node's value is current.
    func updateIfNecessary() { _updateIfNecessary() }

    /// Removes the observer with the given identity from this node's observer list.
    func removeObserver(identity id: ObjectIdentifier) { _removeObserver(id) }

    /// Marks this node `.check` and propagates `.check` downstream.
    func invalidateCheck() { _invalidateCheck() }
}

// MARK: - ReactiveNode

/// The backing storage for both `State` (source node) and `DerivedState` (derived node).
///
/// Source nodes have no computation; their value is written directly via `write(_:)`.
/// Derived nodes hold a computation closure and use three-state lazy evaluation:
/// they recompute only when read, and only when at least one source edge reports a
/// changed value since the last computation.
///
/// All mutable fields are `nonisolated(unsafe)` and serialized by `lock`.
// SPEC: behavior.reactive.derivation — the write path and the updateIfNecessary pull
// path together implement recompute-on-change propagation.
// SPEC: behavior.reactive.equality-gating — per-edge snapshot comparison in
// updateIfNecessary drives revert detection and stops needless recomputation.
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
    private nonisolated(unsafe) var sources: [SourceEdge] = []
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
    ///
    /// The value is read under the lock before edge registration so the snapshot
    /// captured by the edge closure reflects exactly what this consumer observed.
    func read() -> Wrapped {
        updateIfNecessary()
        // Read the value first (under lock) so the snapshot is stable before
        // we build the edge closure. The lock is released before the frame
        // operations to keep user-body code outside the lock.
        let value = lock.withLock { _ in cachedValue! }
        if let frame = ReactiveContextKey.current {
            // Deduplicate before allocating closures: repeat reads of the same
            // source within one run are the common case on this hot path.
            if !frame.isTracked(ObjectIdentifier(self)) {
                lock.withLock { _ in observers.append(frame.observer) }
                // SPEC: behavior.reactive.equality-gating — snapshot the value this
                // consumer observed; the closure captures it to answer "has this
                // source changed since I last saw it?" during validation.
                let seenValue = value
                // The edge's node handle retains this node strongly for the edge's
                // lifetime, so the closure captures self strongly too — the edge and
                // its source live and die together.
                frame.track(
                    AnyReactiveNode(node: self),
                    hasChangedSinceSeen: {
                        self.lock.withLock { _ in
                            guard let current = self.cachedValue else { return true }
                            return !self.isEqual(seenValue, current)
                        }
                    }
                )
            }
        }
        return value
    }

    // MARK: Write (State only)

    /// Stores a new value and notifies observers.
    ///
    /// An equal value is a no-op: not stored and no dependent is notified
    /// (equality-gated write invariant from `domain.state`).
    ///
    /// A changed value marks direct observers `.check` rather than `.dirty`:
    /// whether the observer actually needs to recompute is decided lazily by
    /// per-edge snapshot comparison at read time.
    // SPEC: behavior.reactive.equality-gating — emits .check (not .dirty) so that
    // source reverts are detectable at validation time via edge snapshots.
    func write(_ newValue: Wrapped) {
        let snapshot: [AnyReactiveNode]? = lock.withLock { _ in
            if let current = cachedValue, isEqual(current, newValue) { return nil }
            cachedValue = newValue
            return observers
        }
        guard let obs = snapshot else { return }
        for observer in obs {
            observer.invalidateCheck()
        }
    }

    // MARK: Propagation

    /// Marks this node `.check` (when currently `.clean`) and propagates `.check`
    /// to downstream observers so they re-validate their edges on the next read.
    /// A node already `.check` (or never computed) has already propagated.
    // SPEC: behavior.reactive.derivation — write path: marks this node check,
    // then propagates check transitively so downstream nodes know to re-validate.
    func invalidateCheck() {
        let snapshot: [AnyReactiveNode]? = lock.withLock { _ in
            guard state == .clean else { return nil }
            state = .check
            return observers
        }
        guard let obs = snapshot else { return }
        for observer in obs {
            observer.invalidateCheck()
        }
    }

    // MARK: Pull / updateIfNecessary

    /// Ensures this node's cached value is current.
    ///
    /// For `.check` nodes, validates each source edge in read order: brings the
    /// source current, then asks whether the edge's snapshot has changed. The first
    /// edge that reports a change triggers a recompute; if no edge changed the node
    /// settles to `.clean` without recomputing.
    // SPEC: behavior.reactive.derivation — pull path: validates sources and recomputes
    // lazily, ensuring a read always reflects the latest inputs through chains of
    // derivations and across multiple paths to the same source.
    // SPEC: behavior.reactive.equality-gating — per-edge snapshot comparison drives
    // the settle-or-recompute decision; a consumer recomputes only when at least one
    // source edge reports a value change since its last computation.
    func updateIfNecessary() {
        let currentState = lock.withLock { _ in state }
        switch currentState {
        case .clean:
            return

        case .check:
            // Validate each source in read order. Bring each source current first,
            // then compare its current value against the per-edge snapshot.
            // On the first edge that reports a change, recompute immediately.
            // If all edges are unchanged, settle to .clean without recomputing.
            let currentSources = lock.withLock { _ in sources }
            for edge in currentSources {
                edge.node.updateIfNecessary()
                if edge.hasChangedSinceSeen() {
                    recompute()
                    return
                }
            }
            // No edge reported a change. Settle to clean only if we are still in
            // .check (a concurrent write could have upgraded us; don't clobber it).
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

    /// Runs the computation, re-collects dependency edges, and commits the new value.
    ///
    /// Downstream observers are left in their current `.check` state; they will
    /// validate their own per-edge snapshots when read, so no dirty-push is needed.
    private func recompute() {
        guard let body else { return }

        // Build the observer handle for this node (used by sources to notify us).
        let myHandle = AnyReactiveNode(node: self)

        // Detach this node from all current sources (dynamic dep re-collection).
        let oldSources = lock.withLock { _ -> [SourceEdge] in
            let old = sources
            sources = []
            return old
        }
        for edge in oldSources {
            edge.node.removeObserver(identity: myHandle.identity)
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
        lock.withLock { _ in
            sources = frame.sources
            cachedValue = newValue
            state = .clean
        }
        // Downstream observers remain in .check. Each will validate its own
        // per-edge snapshot when read and recompute only if that edge changed.
        // No dirty-push is needed or correct here.
    }
}
