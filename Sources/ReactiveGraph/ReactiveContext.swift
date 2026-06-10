// SPEC: domain.signal
// The reactive context is the task-local current-computation frame.
// It is a load-bearing spec contract: task-local (not thread-local, not global)
// so it propagates across `await` and into structured child tasks.

// SPEC: domain.owner
// A root owner is bound task-locally alongside the reactive context so that
// computations created inside withReactiveScope are associated with a scope.

// MARK: - SourceEdge

/// A tracked dependency edge from a consumer node to one of its sources.
///
/// Captures the value the consumer last observed from this source (the snapshot)
/// so that validation can determine whether the source has actually changed
/// since the consumer's last computation, enabling revert detection.
// SPEC: behavior.reactive.equality-gating — per-edge value snapshot; the
// hasChangedSinceSeen closure compares the snapshot against the source's
// current value using the source's own equality policy.
struct SourceEdge {
    /// Handle to the source node (used for updateIfNecessary and observer removal).
    let node: AnyReactiveNode

    /// Returns `true` when the source's current value differs from the value
    /// this consumer last observed (the per-edge snapshot).
    let hasChangedSinceSeen: () -> Bool
}

// MARK: - ReactiveFrame

/// A reactive computation currently running.
///
/// Carries a handle pointing back to the observer node (the derived node whose
/// body is currently executing) so that each source read during the body can
/// register the observer in its own `observers` list. Also accumulates the
/// source edges seen during this run for use as the new `sources` list.
final class ReactiveFrame: @unchecked Sendable {
    // @unchecked Sendable: a frame is created, used, and discarded within a single
    // synchronous recompute() call and never escapes it. Async computation bodies
    // (where structured child tasks could call track(_:hasChangedSinceSeen:)
    // concurrently) are not implemented yet; revisit this conformance when they land.

    /// Handle pointing to the observer node (the derived node being evaluated),
    /// registered with each source read during the run.
    let observer: AnyReactiveNode

    /// Source edges accumulated during this run; becomes the node's new `sources`.
    var sources: [SourceEdge] = []

    init(observer: AnyReactiveNode) {
        self.observer = observer
    }

    /// Identity set for fast deduplication; kept in sync with `sources`.
    private var trackedIdentities: Set<ObjectIdentifier> = []

    /// Returns `true` if a source with the given identity is already tracked.
    func isTracked(_ id: ObjectIdentifier) -> Bool {
        trackedIdentities.contains(id)
    }

    /// Records a dependency edge to the given source node with its snapshot comparison.
    func track(_ node: AnyReactiveNode, hasChangedSinceSeen: @escaping () -> Bool) {
        trackedIdentities.insert(node.identity)
        sources.append(SourceEdge(node: node, hasChangedSinceSeen: hasChangedSinceSeen))
    }
}

// MARK: - ReactiveOwner

/// A root owner that provides a scope for reactive computations.
/// Cleanup and disposal are out of scope this pass.
final class ReactiveOwner: @unchecked Sendable {
    // SPEC: manual — minimal placeholder; lifecycle hooks are a later spec.
}

// SPEC: domain.signal
/// The task-local reactive context. A non-nil value means a computation is
/// currently evaluating; reads inside that computation register dependency edges.
enum ReactiveContextKey {
    @TaskLocal static var current: ReactiveFrame? = nil
}

// SPEC: domain.owner
/// The task-local current owner scope, set by `withReactiveScope`.
enum ReactiveOwnerKey {
    @TaskLocal static var current: ReactiveOwner? = nil
}
