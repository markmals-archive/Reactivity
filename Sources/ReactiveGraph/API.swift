// SPEC: manual
// Placeholder for the not-yet-implemented surface; carries no behavioral contract.
private func todo() -> Never {
    fatalError("Not yet implemented")
}

public typealias Dispose = () -> Void

// SPEC: domain.owner
@discardableResult
public func withReactiveScope<T>(_ root: @escaping (@escaping Dispose) async throws -> T)
    async rethrows -> T
{
    todo()
}

@discardableResult
public func withReactiveScope<T>(_ root: @escaping (@escaping Dispose) throws -> T) rethrows -> T {
    todo()
}

@discardableResult
public func withReactiveScope<T>(_ root: @escaping () async throws -> T) async rethrows -> T {
    todo()
}

/// Runs `root` under a fresh reactive owner scope and returns its result.
///
/// All reactive computations created inside `root` are associated with this
/// scope. The owner is bound as a task-local value so it propagates into
/// structured child tasks but not detached tasks.
@discardableResult
public func withReactiveScope<T>(_ root: @escaping () throws -> T) rethrows -> T {
    let owner = ReactiveOwner()
    return try ReactiveOwnerKey.$current.withValue(owner) {
        try root()
    }
}

// SPEC: domain.observer
public struct ObservationHandle: Sendable {
    public func dispose() {
        todo()
    }
}

public struct ObservationOptions: Sendable {
    public var name: String? = nil
    public init() {}
}

// SPEC: domain.observer
@discardableResult
public func observe(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping () -> Void
) -> ObservationHandle {
    todo()
}

@discardableResult
public func observe(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping () async -> Void
) async -> ObservationHandle {
    todo()
}

@discardableResult
public func observe(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping () throws -> Void
) rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping () async throws -> Void
) async rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next>(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Next?) -> Next
) -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next>(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Next?) async -> Next
) async -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next>(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Next?) throws -> Next
) rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next>(
    isolation: isolated (any Actor)? = #isolation,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Next?) async throws -> Next
) async rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init? = nil,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) -> Next
) -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init? = nil,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) async -> Next
) async -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init? = nil,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) throws -> Next
) rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init? = nil,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) async throws -> Next
) async rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) -> Next
) -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) async -> Next
) async -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) throws -> Next
) rethrows -> ObservationHandle {
    todo()
}

@discardableResult
public func observe<Next, Init>(
    isolation: isolated (any Actor)? = #isolation,
    initialValue: Init,
    options: ObservationOptions = .init(),
    _ onChange: @escaping (Init?, Next) async throws -> Next
) async rethrows -> ObservationHandle {
    todo()
}

// SPEC: domain.owner
public func onCleanup(_ cleanupCallback: @escaping () -> Void) {
    todo()
}

public func onCleanup(_ cleanupCallback: @escaping () async -> Void) async {
    todo()
}

// SPEC: error.reactive.unhandled
public func onError(
    _ body: @escaping () throws -> Void, handle handler: @escaping (any Error) -> Void
) {
    todo()
}

public func onError(
    _ body: @escaping () async throws -> Void, handle handler: @escaping (any Error) async -> Void
) async {
    todo()
}

public func onError(
    _ body: @escaping () throws -> Void, handle handler: @escaping (any Error) throws -> Void
) rethrows {
    todo()
}

public func onError(
    _ body: @escaping () async throws -> Void,
    handle handler: @escaping (any Error) async throws -> Void
) async rethrows {
    todo()
}

// SPEC: behavior.reactive.untracking
public func withoutTracking<T>(_ body: () throws -> T) rethrows -> T {
    todo()
}

public func withoutTracking<T>(_ body: () async throws -> T) async rethrows -> T {
    todo()
}

// SPEC: domain.signal
public protocol ReadableSignal<Wrapped> {
    associatedtype Wrapped
    var wrappedValue: Wrapped { get }
}

// SPEC: domain.signal
public protocol WritableSignal<Wrapped>: ReadableSignal {
    associatedtype Wrapped
    var wrappedValue: Wrapped { get nonmutating set }
}

// SPEC: domain.state
@propertyWrapper
public struct State<Wrapped>: WritableSignal, Sendable {
    private let node: ReactiveNode<Wrapped>

    /// Creates a source node with `wrappedValue` as its initial value.
    ///
    /// `Wrapped` is not `Equatable`, so writes cannot be equality-gated:
    /// every write notifies dependents.
    public init(wrappedValue: Wrapped) {
        node = ReactiveNode(value: wrappedValue, isEqual: { _, _ in false })
    }

    /// Reads the current value, registering a dependency edge when called from
    /// inside a reactive computation. Writes notify all current dependents unless
    /// the new value equals the current one.
    public var wrappedValue: Wrapped {
        get { node.read() }
        nonmutating set { node.write(newValue) }
    }

    /// Returns this wrapper itself; copying a `State` shares the underlying node.
    public var projectedValue: Self { self }

    // SPEC: behavior.reactive.untracking
    public func peek() -> Wrapped { todo() }
}

extension State where Wrapped: Equatable {
    /// Creates a source node whose writes are equality-gated: assigning a value
    /// equal to the current one is a no-op and notifies no dependents.
    public init(wrappedValue: Wrapped) {
        node = ReactiveNode(value: wrappedValue, isEqual: ==)
    }
}

// SPEC: domain.derived-state
@propertyWrapper
public struct DerivedState<Wrapped>: ReadableSignal, Sendable {
    private let node: ReactiveNode<Wrapped>

    /// Creates a derived node whose value is produced lazily by `expression`.
    ///
    /// The expression is not evaluated until the first read (lazy invariant).
    /// Subsequent reads return the cached value unless a dependency has changed.
    public init(wrappedValue expression: @autoclosure @escaping () throws -> Wrapped) {
        node = ReactiveNode(body: expression, isEqual: { _, _ in false })
    }

    /// Reads the current value, recomputing if any dependency has changed since
    /// the last read. Registers a dependency edge when called from inside a
    /// reactive computation.
    public var wrappedValue: Wrapped { node.read() }

    /// Returns this wrapper itself; copying a `DerivedState` shares the underlying node.
    public var projectedValue: Self { self }
}

extension DerivedState where Wrapped: Equatable {
    /// Creates a derived node with equality-gated change propagation: when a
    /// recompute yields a value equal to the previous one, downstream dependents
    /// are not notified.
    public init(wrappedValue expression: @autoclosure @escaping () throws -> Wrapped) {
        node = ReactiveNode(body: expression, isEqual: ==)
    }
}

// SPEC: domain.context
@propertyWrapper
public struct Context<Wrapped>: Sendable {
    public init(wrappedValue: Wrapped) {
        todo()
    }

    public var wrappedValue: Wrapped {
        todo()
    }

    public var projectedValue: ContextHandle<Wrapped> {
        todo()
    }
}

// SPEC: domain.context
public struct ContextHandle<Wrapped>: Sendable {
    @discardableResult
    public func withValue<Passthrough>(_ body: () throws -> Passthrough) rethrows -> Passthrough {
        todo()
    }

    @discardableResult
    public func withValue<Passthrough>(_ value: Wrapped, _ body: () throws -> Passthrough) rethrows
        -> Passthrough
    {
        todo()
    }

    @discardableResult
    public func withValue<Passthrough>(_ body: () async throws -> Passthrough) async rethrows
        -> Passthrough
    {
        todo()
    }

    @discardableResult
    public func withValue<Passthrough>(_ value: Wrapped, _ body: () async throws -> Passthrough)
        async rethrows
        -> Passthrough
    {
        todo()
    }
}
