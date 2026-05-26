extension Transducer where Effect == TransducerEffect<Event, Env, Output> {
    
    /// Returns an effect which when invoked starts an async throwing operation isolated to a global actor
    /// tracked by the effect engine.
    ///
    /// The `operation` closure receives an ``Input`` handle for dispatching events and
    /// the captured `Env` for dependencies. Named tasks are automatically cancelled when
    /// the view disappears, or when ``cancel(_:)`` is returned from `update` with the
    /// same identifier.
    ///
    /// - Important: Managed cancellation takes precedence over racing task failures.
    ///   If the runtime cancels a tracked task and the operation concurrently throws,
    ///   the effect engine may classify that outcome as cancellation rather than as a
    ///   system error. This is intentional: once a task has been superseded or
    ///   cancelled by the runtime, late failures from that obsolete work no longer
    ///   participate in global error escalation.
    ///
    /// Prefer ``run(id:priority:option:operation:)`` for fire-and-forget tasks and
    /// ``request(id:priority:option:operation:)`` for perform-driven tasks rather than
    /// constructing `.task` directly.
    ///
    /// - Parameters:
    ///   - id: An optional identifier used to track and cancel the task. Pass `nil` for
    ///     anonymous tasks that run to completion without cancellation support.
    ///   - priority: The `TaskPriority` for the launched task. Pass `nil` to inherit
    ///     the current task's priority.
    ///   - option: Defines how overlapping waiters for the same `id` are handled.
    ///     `.subscribe` keeps the running task and attaches the new waiter to it.
    ///     `.switchToLatest` cancels the running task, starts a fresh one, and moves
    ///     all current waiters for that identifier onto the replacement task.
    ///   - operation: The async work to perform. Returns an optional `Output` value
    ///     forwarded to any caller suspended on ``Input/request(_:)``.
    ///
    /// - Returns: The effect.
    // TODO: Explain clearly what it means when an operation throws.
    // Usually, operations should not fail, but in some cases, the operation may use
    // an input to send events back to the system and *this* input can fail due to a "system error". System
    // errors are critical errors - that is, it might mean, the actor is deallocated,
    // or a potential event buffer overflowed, or some other system error occurred.
    // That means the transducer is no longer guaranteed to perform correctly. The
    // best course of action is to tear down the transducer and actor, and forward
    // the error to event senders and waiters.
    @inline(__always)
    public static func task(
        id: TaskIdentifier? = nil,
        priority: TaskPriority? = nil,
        option: TaskExecutionOption = .switchToLatest,
        operation: @escaping @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Env) async throws -> Output?
    ) -> Effect {
        .init(._task(id: id, priority: priority, option: option, operation: operation))
    }
    
    /// Returns an effect which when invoked starts an async throwing operation isolated to the system actor
    /// tracked by the effect engine.
    ///
    /// The `isolatedOperation` closure receives an ``Input`` handle for dispatching events and
    /// the captured `Env` for dependencies. Named tasks are automatically cancelled when
    /// the view disappears, or when ``cancel(_:)`` is returned from `update` with the
    /// same identifier.
    ///
    /// - Important: Managed cancellation takes precedence over racing task failures.
    ///   If the runtime cancels a tracked task and the operation concurrently throws,
    ///   the effect engine may classify that outcome as cancellation rather than as a
    ///   system error. This is intentional: once a task has been superseded or
    ///   cancelled by the runtime, late failures from that obsolete work no longer
    ///   participate in global error escalation.
    ///
    /// Prefer ``run(id:priority:option:operation:)`` for fire-and-forget tasks and
    /// ``request(id:priority:option:operation:)`` for perform-driven tasks rather than
    /// constructing `.task` directly.
    ///
    /// - Parameters:
    ///   - id: An optional identifier used to track and cancel the task. Pass `nil` for
    ///     anonymous tasks that run to completion without cancellation support.
    ///   - priority: The `TaskPriority` for the launched task. Pass `nil` to inherit
    ///     the current task's priority.
    ///   - option: Defines how overlapping waiters for the same `id` are handled.
    ///     `.subscribe` keeps the running task and attaches the new waiter to it.
    ///     `.switchToLatest` cancels the running task, starts a fresh one, and moves
    ///     all current waiters for that identifier onto the replacement task.
    ///   - isolatedOperation: The async work to perform. Returns an optional `Output` value
    ///     forwarded to any caller suspended on ``Input/request(_:)``.
    ///
    /// - Returns: An effect.
    @inline(__always)
    public static func task(
        id: TaskIdentifier? = nil,
        priority: TaskPriority? = nil,
        option: TaskExecutionOption = .switchToLatest,
        isolatedOperation: @escaping (any TransducerInput<Event, Output>, Env, isolated any Actor) async throws -> Output?
    ) -> Effect {
        .init(._taskIsolated(id: id, priority: priority, option: option, isolatedOperation: isolatedOperation))
    }
    
    /// Return an effect which when invoked executes a synchronous step that may produce the next
    /// event to process immediately.
    ///
    /// The `action` closure receives `Env` and returns the next `Event` to feed back
    /// into `update`, or `nil` to end the chain. The entire chain runs synchronously
    /// on the system actor before any other work proceeds.
    ///
    /// Unlike named tasks, actions do not participate in overlap management. If a
    /// caller is suspended on ``Input/request(_:)``, the caller simply waits until the
    /// synchronous action chain terminates or reaches a terminal task.
    ///
    /// - Parameter action: A synchronous closure receiving `Env` and returning an
    ///   optional next event.
    ///
    /// - Warning: Action chains unwind entirely on the system actor.
    ///   A cycle — two events that each produce an `.action` pointing back at the other —
    ///   may cause an infinite loop. Use ``run(id:priority:option:operation:)`` for any work
    ///   that could repeat or loop.
    ///
    /// - Returns: An effect.
    @inline(__always)
    public static func action(
        _ action: @escaping (Env) -> Event?
    ) -> Effect {
        .init(._actionSync(action))
    }
    
    /// Return an effect which when invoked executes an async step on a user specified global actor
    /// that may produce the next event to process immediately.
    ///
    /// The `action` closure receives `Env` and returns the next `Event` to feed back
    /// into `update`, or `nil` to end the chain. The entire chain runs synchronously
    /// on the system actor before any other work proceeds.
    ///
    /// Async actions still do not create managed task identities of their own. Any
    /// overlap semantics apply only once the chain reaches a named terminal task.
    ///
    /// - Parameter action: A synchronous closure receiving `Env` and returning an
    ///   optional next event.
    ///
    /// - Warning: Action chains unwind entirely on the system actor without yielding.
    ///   A cycle — two events that each produce an `.action` pointing back at the other —
    ///   may cause an infinite loop. Use ``run(id:priority:option:operation:)`` for any work
    ///   that could repeat or loop.
    ///
    /// - Returns: An effect.
    @inline(__always)
    public static func action(
        _ action: @escaping @Sendable @isolated(any) (Env) async -> sending Event?
    ) -> Effect {
        .init(._actionAsync(action))
    }
    
    /// Return an effect which when invoked executes an async step on the system actor
    /// that may produce the next event to process immediately.
    ///
    /// The `action` closure receives `Env` and returns the next `Event` to feed back
    /// into `update`, or `nil` to end the chain. The entire chain runs synchronously
    /// on the system actor before any other work proceeds.
    ///
    /// Async isolated actions still do not create managed task identities of their own.
    /// Any overlap semantics apply only once the chain reaches a named terminal task.
    ///
    /// - Parameter action: A synchronous closure receiving `Env` and returning an
    ///   optional next event.
    ///
    /// - Warning: Action chains unwind entirely on the system actor without yielding.
    ///   A cycle — two events that each produce an `.action` pointing back at the other —
    ///   may cause an infinite loop. Use ``run(id:priority:option:operation:)`` for any work
    ///   that could repeat or loop.
    ///
    /// - Returns: An effect.
    @inline(__always)
    public static func action(
        _ action: @escaping (Env, isolated any Actor) async -> sending Event?
    ) -> Effect {
        .init(._actionAsyncIsolated(action))
    }
    
    /// Returns an effect which when invoked feeds `event` back into `update` immediately, in
    /// the current synchronous turn.
    ///
    /// - Parameter event: The next event to feed directly back into `update`.
    /// - Returns: An effect.
    @inline(__always)
    public static func event(_ event: Event) -> Effect {
        .init(._event(event))
    }
    
    /// Returns an effect which cancels the running task with the given identifier, if any.
    ///
    /// - Parameter id: The logical task identifier to cancel.
    /// - Returns: An effect.
    @inline(__always)
    public static func cancel(_ id: TaskIdentifier) -> Effect {
        .init(._cancel(id))
    }
    
    /// Returns an effect which contains a sequence of effects. The effects will be executed
    /// from left to right, associating the caller's continuation with the last effect only.
    ///
    /// ```swift
    /// // Cancel a stale load before starting a refresh:
    /// return sequence([cancel("load"), .refreshMovies()])
    /// ```
    ///
    /// - Important: Intermediate effects must be synchronous and terminal (`.cancel`
    ///   or side-effect `action` closures). An intermediate effect that returns an
    ///   event is not supported — the event is silently discarded. Use a dedicated
    ///   `update` step for event-producing chains instead.
    ///
    /// - Parameter effects: The ordered effects to execute from left to right.
    /// - Returns: An effect.
    @inline(__always)
    public static func sequence(_ effects: [Effect]) -> Effect {
        .init(._sequence(effects))
    }
}


extension Transducer where Effect == TransducerEffect<Event, Env, Output> {

    /// Returns an effect which, when invoked, starts a fire-and-forget async task that communicates
    /// back through events.
    ///
    /// Use for long-running background work — timers, observers, subscriptions — where
    /// the caller does not need to await a result. The `operation` closure receives an
    /// ``Input`` handle and the captured `Env`; any return value is discarded.
    ///
    /// Managed cancellation follows ``task(id:priority:option:operation:)`` semantics:
    /// if the runtime cancels this task, that cancellation takes precedence over any
    /// racing late failure from the operation.
    ///
    /// ```swift
    /// return run(id: "ticker") { input, env in
    ///     do {
    ///         while true {
    ///             try await env.clock.sleep(for: .seconds(1))
    ///             input(.tick)
    ///         }
    ///     } catch {}
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - id: Optional logical identifier for tracking and overlap policy.
    ///   - priority: Optional `TaskPriority` for the launched task.
    ///   - option: The overlap policy to apply when another task with the same
    ///     identifier is started.
    ///   - operation: The fire-and-forget async work to perform.
    /// - Returns: An effect.
    @inline(__always)
    public static func run(
        id: TaskIdentifier? = nil,
        priority: TaskPriority? = nil,
        option: TaskExecutionOption = .switchToLatest,
        operation: @escaping @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Env) async -> Void
    ) -> Effect where Env: Sendable {
        .init(._task(id: id, priority: priority, option: option) { input, env in
            await operation(input, env)
            return nil
        })
    }
    
    /// Returns an effect which, when invoked, starts a fire-and-forget async task that communicates
    /// back through events.
    ///
    /// Use for long-running background work — timers, observers, subscriptions — where
    /// the caller does not need to await a result. The `operation` closure receives an
    /// ``Input`` handle and the captured `Env`; any return value is discarded.
    ///
    /// Managed cancellation follows ``task(id:priority:option:isolatedOperation:)`` semantics:
    /// if the runtime cancels this task, that cancellation takes precedence over any
    /// racing late failure from the operation.
    ///
    /// ```swift
    /// return run(id: "ticker") { input, env in
    ///     do {
    ///         while true {
    ///             try await env.clock.sleep(for: .seconds(1))
    ///             input(.tick)
    ///         }
    ///     } catch {}
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - systemActor: The host actor isolation forwarded into `isolatedOperation`.
    ///   - id: Optional logical identifier for tracking and overlap policy.
    ///   - priority: Optional `TaskPriority` for the launched task.
    ///   - option: The overlap policy to apply when another task with the same
    ///     identifier is started.
    ///   - isolatedOperation: The fire-and-forget async work to perform on the host actor.
    /// - Returns: An effect.
    @inline(__always)
    public static func run(
        systemActor: isolated (any Actor)? = #isolation,
        id: TaskIdentifier? = nil,
        priority: TaskPriority? = nil,
        option: TaskExecutionOption = .switchToLatest,
        isolatedOperation: @escaping (any TransducerInput<Event, Output>, Env, isolated any Actor) async -> Void
    ) -> Effect where Env: Sendable {
        .init(._taskIsolated(id: id, priority: priority, option: option) { input, env, isolation in
            precondition(
                systemActor != nil && systemActor === isolation,
                "taskIsolated requires a non-nil matching system actor. Actor hosts must provide isolation. Expected \(String(describing: systemActor)), got \(isolation)."
            )
            await isolatedOperation(input, env, isolation)
            return nil
        })
    }


    /// Starts an async task whose result is returned to the caller of ``Input/request(_:)``.
    ///
    /// The `operation` closure performs its work, drives the FSM to a completion event
    /// via `await input.request(...)`, and returns the resulting `Output?` to the
    /// original waiter. Use this when the call site needs to `await` the outcome of an
    /// async operation.
    ///
    /// Managed cancellation follows ``task(id:priority:option:operation:)`` semantics:
    /// if the runtime cancels this task, that cancellation takes precedence over any
    /// racing late failure from the operation.
    ///
    /// ```swift
    /// return .request(id: "load") { input, env in
    ///     let user = await env.api.fetchUser()
    ///     return await input.request(.loaded(user))
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - id: Optional logical identifier for tracking and overlap policy.
    ///   - priority: Optional `TaskPriority` for the launched task.
    ///   - option: The overlap policy to apply when another task with the same
    ///     identifier is started.
    ///   - operation: The async work whose terminal result resumes the original waiter.
    /// - Returns: An effect.
    @inline(__always)
    public static func request(
        id: TaskIdentifier? = nil,
        priority: TaskPriority? = nil,
        option: TaskExecutionOption = .switchToLatest,
        operation: @escaping @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Env) async -> Output?
    ) -> Effect {
        .init(._task(id: id, priority: priority, option: option, operation: operation))
    }
    
}
