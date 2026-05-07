
/// Describes a side effect returned from `update`.
///
/// `Env` is forwarded to every effect so operations and actions have access to
/// dependencies without capturing them directly:
///
/// ```swift
/// // In update:
/// return .task { input, env in          // env forwarded here
///     let result = await env.service.fetch()
///     input(.loaded(result))
/// }
///
/// return .action { env in              // env forwarded here
///     env.analytics.track(.buttonTapped)
///     return .next
/// }
/// ```
public enum Effect<Event, Env> {

    /// Starts an async operation. The `operation` closure receives a `send` function
    /// and the captured `Env`. Named tasks are cancelled and replaced if re-issued.
    case task(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: @Sendable @isolated(any) (Input<Event>, Env) async -> Void
    )

    /// A synchronous step. The `action` closure receives `Env` and may return the
    /// next `Event` to process immediately in the same run loop.
    case action(
        action: @Sendable (Env) -> Event?
    )
    
    /// Sends the given event back into the system which will be processed
    /// immediately.
    case event(Event)
    
    /// Cancels a running named task.
    case cancel(String)

    /// Executes a list of effects left to right. Each effect is processed in order;
    /// only the last effect in the sequence is associated with the caller's continuation.
    ///
    /// Intermediate effects must be synchronous and terminal (`.cancel`, side-effect
    /// `.action` closures). Intermediate effects that return an event are not supported
    /// and the event will be discarded — use a separate `update` step for event chains.
    ///
    /// ```swift
    /// // Cancel a stale load before starting a refresh:
    /// return .sequence([.cancel("load"), .refreshMovies()])
    /// ```
    case sequence([Effect<Event, Env>])
}
