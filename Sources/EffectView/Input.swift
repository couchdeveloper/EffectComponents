
/// A lightweight, `Sendable` handle for dispatching events into the FSM + EffectManager.
///
/// `Input` provides three dispatch strategies with different synchronisation semantics:
/// - ``send(_:)`` — synchronous, fire-and-forget; must already be on the `@MainActor`.
/// - ``enqueue(_:)`` — schedules the event on the `@MainActor` without awaiting it; safe to call from any isolation.
/// - ``perform(_:)`` — suspends the caller until the event has been fully processed.
///
/// ## Isolation and lifetime safety
/// All state mutations run on the `@MainActor`, which is a global, app-lifetime executor.
/// Because the `@MainActor` is never cancelled or destroyed, ``perform(_:)`` is guaranteed
/// to resume its continuation on every code path — no `withTaskCancellationHandler`
/// bookkeeping is required.
///
/// If the calling `Task` is cancelled while awaiting ``perform(_:)``, the suspension
/// continues until the event is processed; Swift does not automatically resume the
/// continuation on cancellation. This is safe here precisely because the `@MainActor`
/// always completes its work.
public struct Input<Event>: Sendable {

    init(send: @escaping @MainActor @Sendable (Event, Input<Event>, CheckedContinuation<Void, Never>?) -> Void) {
        self._send = send
    }
        
    private var _send: @Sendable @MainActor (Event, Input<Event>, CheckedContinuation<Void, Never>?) -> Void

    /// Sends `event` synchronously. The caller must already be running on the `@MainActor`.
    @MainActor
    public func send(_ event: Event) {
        _send(event, self, nil)
    }
    
    /// Schedules `event` to be sent on the `@MainActor` without awaiting its processing.
    /// Safe to call from any actor isolation or a non-isolated context.
    @inline(__always)
    public func enqueue(_ event: sending Event) {
        Task { @MainActor in
            send(event)
        }
    }

    /// Sends `event` and suspends until the entire resulting effect chain has completed.
    ///
    /// A single event can trigger a cascade: an `.action` may return the next event to
    /// process immediately, which in turn may return another, and so on. The continuation
    /// is threaded through the whole chain and only resumed when the chain reaches a
    /// terminal effect — typically a `.task`, whose async operation runs to completion
    /// before `perform` returns.
    ///
    /// ```
    /// event → action (→ event → action …) → task  ← perform resumes here
    ///                                      └─ or nil effect / .cancel
    /// ```
    ///
    /// The caller hops to the `@MainActor` for the duration of the call. Because the
    /// `@MainActor` is a global, app-lifetime executor, the continuation is always
    /// resumed — no cancellation handler is needed.
    ///
    /// > Note: If the calling `Task` is cancelled while suspended, `perform` continues
    /// > to wait until the effect chain settles naturally.
    @MainActor
    public func perform(_ event: sending Event) async -> Void {
        await withCheckedContinuation { continuation in
            self._send(event, self, continuation)
        }
    }

    /// Convenience call-as-function syntax for ``enqueue(_:)``.
    @inline(__always)
    public func callAsFunction(_ event: sending Event) {
        enqueue(event)
    }
}
