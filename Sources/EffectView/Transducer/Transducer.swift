import Foundation

/// Finite-state reducer contract for the effect runtime.
///
/// A `Transducer` defines the domain model that `EffectView` or
/// `EffectObservable` hosts: mutable `State`, incoming `Event`s, optional
/// dependency `Env`, and the ``TransducerEffect`` values returned from
/// ``update(_:event:)``.
///
/// The runtime treats ``update(_:event:)`` as the single mutation point.
/// `update` mutates state synchronously and may return an effect describing
/// follow-up work. That work can emit more events later, but direct state
/// mutation still flows back through `update`.
public protocol Transducer {
    /// Mutable feature state owned by the host runtime.
    associatedtype State

    /// Domain event type that drives state transitions.
    associatedtype Event

    /// Value returned to callers suspended on `request`-style entry points.
    ///
    /// Use `Void` when the feature does not return a result.
    associatedtype Output = Void

    /// Dependency environment captured for the runtime lifetime.
    ///
    /// Use `Void` when the feature has no external dependencies.
    associatedtype Env = Void

    /// Effect type returned from ``update(_:event:)``.
    associatedtype Effect = TransducerEffect<Event, Env, Output>
    
    /// Applies `event` to `state` and returns the next effect to execute.
    ///
    /// `update` is synchronous. Mutate `state` directly and return an optional
    /// effect describing any follow-up work. Return `nil` when processing ends
    /// with no further effect.
    ///
    /// - Parameters:
    ///   - state: The current mutable feature state.
    ///   - event: The incoming event to reduce.
    /// - Returns: The next effect to execute, or `nil` if processing terminates.
    static func update(_ state: inout State, event: Event) -> Effect?
    
    /// Produces the terminal result for a settled request-style event chain.
    ///
    /// The runtime calls `output` when a `request` reaches a terminal state
    /// without handing its continuation off to a managed task.
    ///
    /// - Parameters:
    ///   - state: The final state after the event chain has settled.
    ///   - event: The terminal event that ended the chain.
    /// - Returns: The value to resume the waiting request with.
    static func output(state: State, event: Event) -> Output
}

/// Continuation used internally to complete request-style callers.
public typealias Continuation<Output> = CheckedContinuation<Output?, Error>


extension Transducer where Output == Void {
    /// Default terminal output for features that do not return a value.
    ///
    /// - Parameters:
    ///   - state: The final state after the event chain has settled.
    ///   - event: The terminal event that ended the chain.
    /// - Returns: `Void`.
    @inline(__always)
    public static func output(state: State, event: Event) -> Output { () }
}


enum ControlEvent: Sendable {
    case systemError(any Swift.Error)
    case cancel
}

enum TaggedEvent<Event> {
    case event(Event)
    case control(ControlEvent)
}

extension TaggedEvent: Sendable where Event: Sendable {}

enum SystemCompletion: Swift.Error {
    case error(any Swift.Error)
    case cancelled
}


// Note:  A Transducer requires an isolation in order to compile!
extension Transducer where Effect == TransducerEffect<Event, Env, Output> {
    
    // Caution: control should not mutate storage!
    static func control(
        systemActor: isolated any Actor = #isolation,
        controlEvent: ControlEvent,
        storage: some Storage<State>,
        taskManager: TaskManager<Output>
    ) throws where Output: Sendable, Env: Sendable {
        var error: Swift.Error? = nil
        switch controlEvent {
        case .systemError(let systemError):
            error = systemError
            taskManager.cancel(with: error)
        case .cancel:
            taskManager.cancel(with: error)
        }
        try taskManager.checkCancellation()
    }

    
    // TODO: document clearly when and why this function throws.
    // Note: *ideally* it should not throw
    
    /// Processes a regular event through `update` until the chain terminates.
    ///
    /// > Important: On normal return, `continuation` has been fully consumed: it was either
    /// resumed during synchronous processing or handed off to `taskManager` for
    /// later completion. If this function throws, it does not resume the
    /// continuation; the caller must handle the thrown error and decide how the
    /// waiting request should complete.
    static func compute<Input: TransducerInput<Event, Output>>(
        systemActor: isolated any Actor = #isolation,
        event: Event,
        continuation: Continuation<Output>?,
        storage: some Storage<State>,
        taskManager: TaskManager<Output>,
        input: Input?,
        env: Env
    ) async throws where Output: Sendable, Env: Sendable, Input: Sendable {
        var nextEvent: Event? = event
        var cont = continuation
        while let event = nextEvent {
            try taskManager.checkCancellation()
            nextEvent = nil
            if let effect = update(&storage.value, event: event) {
                (nextEvent, cont) = try await executeEffect(
                    effect,
                    continuation: cont,
                    taskManager: taskManager,
                    input: input,
                    env: env
                )
            } else {
                if let continuation {
                    let output = output(state: storage.value, event: event)
                    continuation.resume(returning: output)
                }
                cont = nil
            }
        }
        assert(cont == nil)
    }

    // TODO: document clearly when and why this function throws.
    // Note: *ideally* it should not throw.
    // Note: it seems, the only case when it throws is a kind of precondition.
    private static func executeEffect<Input: TransducerInput<Event, Output>>(
        systemActor: isolated any Actor = #isolation,
        _ effect: Effect,
        continuation: Continuation<Output>?,
        taskManager: TaskManager<Output>,
        input: Input?,
        env: Env
    ) async throws -> (Event?, Continuation<Output>?) where Output: Sendable, Env: Sendable, Input: Sendable {
        switch effect {
        case ._task(id: let identifier, priority: let priority, let option, operation: let operation):
            guard let input else {
                // TODO: Check if this should be better a precondition
                throw RuntimeError.noInput
            }
            taskManager.addTask(
                with: identifier,
                option: option,
                continuation: continuation,
                priority: priority,
                isolatedOperation: { _ in
                    try await operation(input, env)
                }
            )
            return (nil, nil)

        case ._taskIsolated(id: let identifier, priority: let priority, let option, isolatedOperation: let isolatedOperation):
            guard let input else {
                // TODO: Check if this should be better a precondition
                throw RuntimeError.noInput
            }
            taskManager.addTask(
                with: identifier,
                option: option,
                continuation: continuation,
                priority: priority,
                isolatedOperation: { isolated in
                    _ = systemActor
                    return try await isolatedOperation(input, env, isolated)
                }
            )
            return (nil, nil)

        case ._event(event: let event):
            return (event, continuation)
            
        case ._actionSync(action: let action):
            let event = action(env)
            if event == nil {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            return (event, continuation)
            
        case ._actionAsync(action: let action):
            let event = await action(env)
            try taskManager.checkCancellation()

            if event == nil {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            return (event, continuation)

        case ._actionAsyncIsolated(action: let action):
            let event = await action(env, systemActor)
            try taskManager.checkCancellation()

            if event == nil {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            return (event, continuation)

        case ._cancel(let identifier):
            taskManager.cancelTasks(with: identifier)
            continuation?.resume(returning: nil)
            return (nil, nil)
            
        case ._sequence(let effects):
            guard let last = effects.last else {
                continuation?.resume(returning: nil)
                return (nil, nil)
            }
            for effect in effects.dropLast() {
                _ = try await executeEffect(
                    effect,
                    continuation: nil,
                    taskManager: taskManager,
                    input: input,
                    env: env
                )
            }
            return try await executeEffect(
                last,
                continuation: continuation,
                taskManager: taskManager,
                input: input,
                env: env
            )

        case .none:
            return (nil, nil)
        }
    }
}
