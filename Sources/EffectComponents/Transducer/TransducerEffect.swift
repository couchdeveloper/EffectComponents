
/// A value describing a side effect to run after a state transition.
///
/// `update` returns an `Effect` to declare what async or synchronous work should
/// happen next. The effect engine executes it; `update` itself stays synchronous
/// and free of side effects. `Env` is forwarded to every effect so operations and
/// actions can access dependencies without capturing them at the call site.
///
/// ```swift
/// // Fire-and-forget task:
/// return run(id: "ticker") { input, env in
///     while true {
///         try await env.clock.sleep(for: .seconds(1))
///         input(.tick)
///     }
/// }
///
/// // Perform-driven task (caller awaits result):
/// return request(id: "load") { input, env in
///     let user = await env.api.fetchUser()
///     return await input.request(.loaded(user))
/// }
///
/// // Synchronous step — next event returned inline:
/// return action { env in
///     env.analytics.track(.buttonTapped)
///     return .next
/// }
/// ```
///
/// - Caution: Effects should only be created on the system actor.
/// - Important: Prefer the documented factory helpers such as
///   ``Transducer/run(id:priority:option:operation:)``,
///   ``Transducer/request(id:priority:option:operation:)``,
///   ``Transducer/action(_:)``, ``Transducer/event(_:)``, and
///   ``Transducer/cancel(_:)`` rather than constructing underscored
///   enum cases directly. The underscored cases are the runtime
///   representation.
///
/// ### Generic parameters
///
/// - `Event`: The event type of the FSM this effect belongs to.
/// - `Env`: The dependency environment forwarded into every task and action closure.
/// - `Output`: The value type returned to a caller suspended on ``Input/request(_:)``.
///   Use `Void` when no return value is needed.
public struct TransducerEffect<Event, Env, Output> {
    let type: EffectType<Event, Env, Output>
    
    init(_ type: EffectType<Event, Env, Output>) {
        self.type = type
    }
}

enum EffectType<Event, Env, Output> {
    
    case none
    
    case _task(
        id: TaskIdentifier?,
        priority: TaskPriority?,
        option: TaskExecutionOption,
        operation: @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Env) async throws -> Output?
    )

    case _taskIsolated(
        id: TaskIdentifier?,
        priority: TaskPriority?,
        option: TaskExecutionOption,
        isolatedOperation: (any TransducerInput<Event, Output>, Env, isolated any Actor) async throws -> Output?
    )

    case _actionSync(
        (Env) -> Event?
    )
    
    case _actionAsync(
        @isolated(any) (Env) async -> sending Event?
    )

    case _actionAsyncIsolated(
        (Env, isolated any Actor) async -> sending Event?
    )

    case _event(Event)
    
    case _cancel(TaskIdentifier)

    case _sequence([TransducerEffect<Event, Env, Output>])
}

