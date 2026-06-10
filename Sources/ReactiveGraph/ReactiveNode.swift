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
    private let _isClean: () -> Bool

    init<W>(node: ReactiveNode<W>) {
        identity = ObjectIdentifier(node)
        _updateIfNecessary = { node.updateIfNecessary() }
        _removeObserver = { id in node.removeObserver(identity: id) }
        _invalidateCheck = { node.invalidateCheck() }
        _isClean = { node.isClean() }
    }

    /// Ensures the node's value is current.
    func updateIfNecessary() { _updateIfNecessary() }

    /// Removes the observer with the given identity from this node's observer list.
    func removeObserver(identity id: ObjectIdentifier) { _removeObserver(id) }

    /// Marks this node `.check` and propagates `.check` downstream.
    func invalidateCheck() { _invalidateCheck() }

    /// Whether the node is currently settled (`.clean`).
    func isClean() -> Bool { _isClean() }
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

    // SPEC: behavior.reactive.write-visibility — realizes domain.signal's no-lost-updates
    // invariant. The node's MUTATION EPOCH: incremented unconditionally by every
    // invalidateCheck() (so a write landing mid-recompute is visible to the commit
    // step even though the node is not `.clean` then) AND by every recompute commit
    // (so a concurrent validator of the same node whose snapshot predates the commit
    // cannot settle `.clean` over the freshly committed state/sources — settles are
    // valid only for the exact epoch they validated).
    private nonisolated(unsafe) var invalidationGeneration: UInt64 = 0

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
    /// Registration and the value copy happen in ONE lock acquisition: a write
    /// completing before it is the value this consumer observes, and a write
    /// landing after it is guaranteed to find the consumer registered and notify
    /// it. Copy-then-register would leave a first-time edge blind to a cross-task
    /// write landing between the two steps (no-lost-updates).
    // SPEC: behavior.reactive.write-visibility — atomic register-and-copy.
    func read() -> Wrapped {
        updateIfNecessary()
        if let frame = ReactiveContextKey.current {
            // Deduplicate before allocating closures: repeat reads of the same
            // source within one run are the common case on this hot path.
            if !frame.isTracked(ObjectIdentifier(self)) {
                // Registration is idempotent: the previous run's entry survives a
                // recompute (sources stay attached until commit — see recompute()),
                // so a re-read of the same source must not add a second entry.
                //
                // The same acquisition also observes this node's state: a derived
                // source re-invalidated between the updateIfNecessary above and
                // this registration has a suspect value AND notified nobody (the
                // consumer was not yet registered) — flag the frame so the
                // consumer's commit settles .check instead of .clean. Source
                // nodes are always .clean, so they never flag.
                let (value, sourceWasInvalidated) = lock.withLock { _ -> (Wrapped, Bool) in
                    if !observers.contains(where: { $0.identity == frame.observer.identity }) {
                        observers.append(frame.observer)
                    }
                    return (cachedValue!, state != .clean)
                }
                if sourceWasInvalidated {
                    frame.markObservedInvalidatedSource()
                }
                // SPEC: behavior.reactive.equality-gating — snapshot the value this
                // consumer observed; the closure captures it to answer "has this
                // source changed since I last saw it?" during validation.
                let seenValue = value
                // The edge's node handle retains this node strongly for the edge's
                // lifetime, so the closure captures self strongly too — the edge and
                // its source live and die together.
                //
                // cachedValue is copied under the lock and isEqual runs outside it:
                // a user comparator that reads the graph would otherwise re-enter
                // this node's Mutex on the same task and deadlock. Comparators that
                // touch the graph are unsupported (spec): unlocked evaluation makes
                // a graph-READING comparator degrade to bounded staleness (settled
                // nodes short-circuit); a graph-WRITING one may recurse unboundedly.
                frame.track(
                    AnyReactiveNode(node: self),
                    hasChangedSinceSeen: {
                        let current = self.lock.withLock { _ in self.cachedValue }
                        guard let current else { return true }
                        return !self.isEqual(seenValue, current)
                    }
                )
                return value
            }
        }
        return lock.withLock { _ in cachedValue! }
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
        // isEqual runs between two lock acquisitions, never under one: a user
        // comparator that reads any reactive value would re-enter this node's
        // Mutex on the same task and deadlock. Comparators that touch the graph
        // are unsupported (spec): unlocked evaluation makes a graph-READING
        // comparator degrade to bounded staleness, while a graph-WRITING one may
        // recurse unboundedly — but never deadlock. Cross-task interleaving
        // between the two acquisitions falls within the already-unspecified
        // ordering of concurrent writes to one source.
        let current = lock.withLock { _ in cachedValue! }
        guard !isEqual(current, newValue) else { return }
        let snapshot = lock.withLock { _ -> [AnyReactiveNode] in
            cachedValue = newValue
            return observers
        }
        for observer in snapshot {
            observer.invalidateCheck()
        }
    }

    // MARK: Propagation

    /// Marks this node `.check` (when currently `.clean`) and propagates `.check`
    /// to downstream observers so they re-validate their edges on the next read.
    ///
    /// The invalidation generation is incremented unconditionally — before the
    /// `.clean` state guard — so a write that arrives while a recompute is already
    /// in progress (state is `.dirty` or `.check`) still advances the generation.
    /// The recompute's commit step compares its pre-body snapshot to detect this and
    /// keeps the node dirty rather than settling it clean, preserving the write.
    // SPEC: behavior.reactive.derivation — write path: marks this node check,
    // then propagates check transitively so downstream nodes know to re-validate.
    // SPEC: behavior.reactive.write-visibility — unconditional generation bump is the
    // mechanism that prevents a mid-recompute write from being swallowed at commit.
    func invalidateCheck() {
        let snapshot: [AnyReactiveNode]? = lock.withLock { _ in
            // Bump unconditionally: even a node that is mid-recompute (.dirty) must
            // record that an invalidation arrived so the commit step can detect it.
            invalidationGeneration &+= 1
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
    // SPEC: error.reactive.cycle — entry walk detects any in-progress evaluation of
    // this node on the current task, covering both recompute bodies and re-validation
    // loops (branch-gated dormant cycles trip here, not just self-read cycles).
    func updateIfNecessary() {
        // Cycle detection: walk the task-local evaluation chain before doing any
        // work. This catches re-entrant calls whether they arrive via a recompute
        // body (self-read / mutual) or via re-validation of a dormant cycle whose
        // branch condition just changed.
        //
        // The walk cost is proportional to evaluation nesting depth (a handful of
        // frames in practice), not graph size. The chain is nil outside any
        // evaluation, so the walk short-circuits immediately on the hot path.
        let myID = ObjectIdentifier(self)
        var cursor = EvaluationChainKey.current
        while let link = cursor {
            if link.nodeID == myID {
                preconditionFailure(
                    "ReactiveGraph: dependency cycle detected — a computation read a value "
                        + "whose evaluation is already in progress on this task."
                )
            }
            cursor = link.next
        }

        let currentState = lock.withLock { _ in state }
        switch currentState {
        case .clean:
            // Fast path: already current. Do NOT push onto the evaluation chain —
            // a clean node does no evaluation work and repeated legitimate reads of
            // the same node at different points in one traversal must not trap.
            return

        case .check:
            // Snapshot the generation before validation begins. If an invalidation
            // arrives while we are walking sources (and determines no recompute is
            // needed), we must not settle to .clean — that would lose the write.
            // SPEC: behavior.reactive.write-visibility — generation guard on settle.
            let genSnapshot = lock.withLock { _ in invalidationGeneration }

            // Push this node onto the evaluation chain for the duration of
            // validation. A source that re-enters updateIfNecessary for THIS node
            // (a dormant cycle whose branch just became active) will find it in the
            // chain and trap. The withValue scope pops automatically on exit.
            let chainEntry = EvaluationChain(nodeID: myID, next: EvaluationChainKey.current)
            EvaluationChainKey.$current.withValue(chainEntry) {
                // Validate each source in read order. Bring each source current first,
                // then compare its current value against the per-edge snapshot.
                // On the first edge that reports a change, recompute immediately.
                // If all edges are unchanged, settle to .clean without recomputing.
                //
                // A source can REFUSE to settle (stay .check) when a write raced its
                // own validation — and propagation may have early-stopped at it, so
                // this node's generation never moved. Settling .clean above a
                // non-clean source would strand that pending invalidation behind our
                // .clean fast path; track settledness and refuse to settle with it.
                // Invariant restored: a clean node has only clean sources.
                // SPEC: behavior.reactive.write-visibility — settle requires settled sources.
                let currentSources = lock.withLock { _ in sources }
                var allSourcesSettled = true
                for edge in currentSources {
                    edge.node.updateIfNecessary()
                    if edge.hasChangedSinceSeen() {
                        recompute()
                        return
                    }
                    if !edge.node.isClean() { allSourcesSettled = false }
                }
                // No edge reported a change. Settle to clean only if the generation
                // is unchanged (no write landed during validation), every source
                // actually settled, and we are still in .check (a concurrent write
                // could have already moved us further).
                if allSourcesSettled {
                    lock.withLock { _ in
                        if state == .check, invalidationGeneration == genSnapshot {
                            state = .clean
                        }
                    }
                }
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

    /// Whether the node is currently settled (`.clean`). Consulted by consumers
    /// at settle time: a consumer may go `.clean` only above clean sources.
    func isClean() -> Bool {
        lock.withLock { _ in state == .clean }
    }

    // MARK: Recompute

    /// Runs the computation, re-collects dependency edges, and commits the new value.
    ///
    /// A changed-value commit notifies observers (`.check` + epoch bump) so no
    /// concurrent validator settles over it; consumers still decide whether to
    /// recompute by per-edge value comparison, never by the notification alone.
    private func recompute() {
        guard let body else { return }

        // Build the observer handle for this node (used by sources to notify us).
        let myHandle = AnyReactiveNode(node: self)

        // Snapshot the invalidation generation before detaching sources and running
        // the body. If invalidateCheck() fires during the body (e.g. a mid-body
        // write to a source this node already registered as an observer), the
        // generation will advance and the commit step will detect it.
        // SPEC: behavior.reactive.write-visibility — pre-body generation snapshot.
        let genSnapshot = lock.withLock { _ in invalidationGeneration }

        // Deferred detach (dynamic dep re-collection): the old source edges stay
        // attached — and this node stays in their observer lists — while the body
        // runs. Detaching first would open a window in which a cross-task write to
        // a source notifies no observer and bumps no generation, silently
        // swallowing the write. Sources the new run no longer reads are pruned
        // after commit; a write to one of them mid-body costs at most one
        // spurious re-validation on the next read.
        // SPEC: behavior.reactive.write-visibility — closes the detach window.
        let oldSources = lock.withLock { _ in sources }

        // Run the body inside a fresh tracking frame, with this node pushed onto
        // the evaluation chain. The chain entry ensures that if the body reads
        // this node — directly (self-read) or through intermediates (mutual cycle,
        // branch-gated dormant cycle) — updateIfNecessary will find the entry and
        // trap before recursing. The withValue scope pops the entry on exit.
        //
        // Note: when recompute() is called from inside the .check validation loop
        // the caller has already pushed a chain entry for this node; pushing again
        // here is harmless (the entry-walk at updateIfNecessary top already ran and
        // passed before this recompute() call, so the duplicate entry is never the
        // one that trips the check).
        let frame = ReactiveFrame(observer: myHandle)
        let newValue: Wrapped
        let chainEntry = EvaluationChain(
            nodeID: myHandle.identity, next: EvaluationChainKey.current)
        do {
            newValue = try EvaluationChainKey.$current.withValue(chainEntry) {
                try ReactiveContextKey.$current.withValue(frame) {
                    try body()
                }
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
        // If the generation advanced during the body a write landed mid-recompute:
        // store the value (it is the best available result) but stay `.check` so
        // the next read re-validates and catches the pending invalidation.
        // SPEC: behavior.reactive.write-visibility — generation guard at commit.
        //
        // The overwritten value and the observer snapshot are captured in the SAME
        // critical section as the overwrite, so the changed/unchanged classification
        // below describes exactly this commit — never a value a concurrent commit
        // already replaced. The comparator itself runs after the lock is released
        // (comparator purity, see write()).
        let (overwrittenValue, observersSnapshot) = lock.withLock {
            _ -> (Wrapped?, [AnyReactiveNode]) in
            let overwritten = cachedValue
            sources = frame.sources
            cachedValue = newValue
            // Settle .clean only if no invalidation arrived during the body —
            // neither via this node's own generation (a write reached a
            // registered observer entry) nor via the frame flag (a first-time
            // source was already re-invalidated at registration).
            let undisturbed =
                invalidationGeneration == genSnapshot && !frame.observedInvalidatedSource
            state = undisturbed ? .clean : .check
            // The commit itself is a mutation: bump the epoch so a concurrent
            // validator of this node holding a pre-commit snapshot cannot settle
            // `.clean` over the state and source set committed here.
            invalidationGeneration &+= 1
            return (overwritten, observers)
        }
        // A changed-value commit notifies observers (.check + epoch bump), exactly
        // like a source write: a consumer whose edge comparison passed against the
        // overwritten value must not settle .clean over this commit — its epoch
        // moves and its settle refuses. An unchanged-value commit stays silent, and
        // a concurrent stale settle is then harmless: the committed value equals
        // the consumer's snapshot. Consumers still gate recomputes by per-edge
        // value comparison, so this notification adds at most a re-validation,
        // never a recompute (behavior.reactive.equality-gating is preserved).
        // SPEC: behavior.reactive.write-visibility — changed-commit notification.
        let valueChanged = overwrittenValue.map { !isEqual($0, newValue) } ?? true
        if valueChanged {
            for observer in observersSnapshot {
                observer.invalidateCheck()
            }
        }

        // Prune observer registrations for sources the new run no longer reads.
        // Doing this after commit keeps the no-lost-updates window closed; a write
        // to a dropped source landing before its prune merely marks this node
        // `.check`, and the next read settles it without recomputing.
        let retainedIdentities = Set(frame.sources.map { $0.node.identity })
        for edge in oldSources where !retainedIdentities.contains(edge.node.identity) {
            edge.node.removeObserver(identity: myHandle.identity)
        }
    }
}
