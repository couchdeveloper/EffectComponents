
/// A value describing a side effect to run after a state transition.
///
/// `update` returns an `Effect` to declare what async or synchronous work should
/// happen next. The effect engine executes it; `update` itself stays synchronous
/// and free of side effects. `Env` is forwarded to every effect so operations and
/// actions can access dependencies without capturing them at the call site.
///
/// ```swift
/// // Fire-and-forget task:
/// return .run(id: "ticker") { input, env in
///     while true {
///         try await env.clock.sleep(for: .seconds(1))
///         input(.tick)
///     }
/// }
///
/// // Perform-driven task (caller awaits result):
/// return .request(id: "load") { input, env in
///     let user = await env.api.fetchUser()
///     return await input.request(.loaded(user))
/// }
///
/// // Synchronous step — next event returned inline:
/// return .action { env in
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
// TODO: Need to exaplain clearly what it means, when an operation throws.
// Usually, operations shouls not fail, but in some cases, the operation may use
// an input to send events back to the system and *this* input can fail due to a "system error". System
// errors are critical errors - that is, it might mean, the actor is deallocated,
// or a potential event buffer did overflow or some other system error occured,
// That means, the transducer is not guaranteed to perform correctly anymoer. The
// best course of action is to tear down the transducer and actor, and forward
// the error to event senders and waiters.
public enum TransducerEffect<Event, Env, Output> {
    
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

