import Foundation

/// A `Sendable` handle for dispatching events into the effect engine.
///
/// `EffectViewInput` provides three dispatch strategies with different semantics:
/// - ``send(_:)`` — synchronous; must be called from the `@MainActor`.
/// - ``post(_:)`` — fire-and-forget; safe from any isolation.
/// - ``request(_:)`` — suspends the caller, returning `Output?`.
///
/// ### Isolation and lifetime safety
///
/// All state mutations run on the `@MainActor`, a global, app-lifetime
/// executor. Because the `@MainActor` is never destroyed, ``request(_:)``
/// is guaranteed to resume its continuation on every code path — no
/// `withTaskCancellationHandler` bookkeeping is required.
///
/// If the calling `Task` is cancelled while awaiting ``request(_:)``,
/// the suspension continues until the event is processed. Swift does not
/// automatically resume continuations on cancellation; this is safe
/// because the `@MainActor` always completes its work.
///
/// ### Generic parameters
///
/// - `Event`: The event type dispatched into the state machine.
/// - `Output`: The value returned by ``request(_:)``.
///   Use `Void` when no return value is needed.
public struct EffectViewInput<Event, Output>: TransducerInput, Identifiable, Sendable {
    
    @MainActor
    init(_ send: Send<Event, EffectViewInput, Output>) {
        self._send = { @MainActor (event, input, continuation) async throws -> Void in
            try await send(event, input: input, continuation: continuation)
        }
        id = send.id
    }
    
    let _send: @MainActor (Event, EffectViewInput, Continuation<Output>?) async throws -> Void
    
    public let id: UUID
    
    
    /// Sends the given event into the transducer.
    ///
    /// The event will be processed by the transducer's update function, which may
    /// return an effect which may itself return an event. This event is synchronously
    /// processed by the update function. The chain of events is processed until no
    /// further events are returned.
    ///
    /// If the update function returns a task effect, this task will be started. This
    /// also terminates the event processing chain and `send` returns.
    ///
    /// When `send` returns the transducer has fully processed the event, that is it has
    /// updated its state accordingly, and started all effect tasks returned by the
    /// update function during processing of the event. However, any async operations
    /// in those tasks may continue to run.
    ///
    /// - seealso: **Effect Operations and Actions**
    ///
    /// > Note: The send function may suspend only when it executes suspending effect
    ///   actions.
    ///
    /// - Parameter event: The event that is sent into the system.
    /// - Throws: ``RuntimeUnavailable`` if the runtime cannot accept the event,
    ///   or `CancellationError` if accepted work is later cancelled.
    ///
    /// ## Example
    ///
    /// Use `send` when you are already running on the `@MainActor` and want the event to be
    /// processed immediately, in the same synchronous turn. A typical example is a SwiftUI
    /// button action:
    ///
    /// ```swift
    /// Button("Increment") {
    ///     // Processed before the next await point:
    ///     input.send(.increment)
    /// }
    /// ```
    ///
    /// "Synchronous" here means that `update` is called inline, any `.action` chain is
    /// unwound, and the resulting state change is applied — all before `send` returns.
    /// If `update` returns a `.task`, that task is *launched* synchronously but runs
    /// concurrently; `send` does not wait for it to finish. Use ``request(_:)`` if you
    /// need to await the task's completion.
    ///
    /// If you want to fire-and-forget the event — scheduling it without waiting for even
    /// the synchronous `update` pass to complete — use ``post(_:)`` instead,
    /// for example, `input.post(.increment)` — or use the shorthand to post
    /// an event: `input(.increment)`.
    ///
    /// - Warning: Because `send` unwinds `.action` chains synchronously on the `@MainActor`,
    ///   a cycle in your `update` function — e.g. `.ping` → `.action { .pong }` → `.action { .ping }` →  … —
    ///   will loop forever and hang the main thread. ``post(_:)`` and ``request(_:)`` are
    ///   immune because each re-entry is scheduled as a new task, yielding control between iterations.
    @MainActor
    public func send(_ event: Event) async throws {
        try await _send(event, self, nil)
    }
    
    /// Schedules `event` on the `@MainActor` without awaiting it.
    ///
    /// Safe to call from any actor isolation or non-isolated context.
    /// Use this to fire-and-forget an event from a background task or a
    /// non-isolated callback without waiting for `update` to run.
    ///
    /// - Parameter event: The event to enqueue into the runtime.
    /// - Throws: This implementation does not throw synchronously. Runtime failures
    ///   surface only inside the scheduled task that later processes the event.
    @inline(__always)
    public func post(_ event: sending Event) throws {
        Task { @MainActor in
            try await _send(event, self, nil)
        }
    }
    
    /// Sends `event` and suspends until operations of the resulting effect chain complete.
    ///
    /// The event will be processed by the transducer's update function, which may
    /// return an effect which may itself return an event. This event is synchronously
    /// processed by the update function. The chain of events is processed until no
    /// further events are returned.
    ///
    /// If the update function returns a task, this task will be executed and `request` will
    /// suspend until the task's operation completes, returning the task's output.
    /// This also terminates the event processing chain.
    ///
    /// When `request` returns the transducer has fully processed the event, that is it has
    /// updated its state accordingly, and started and awaited the effect task returned
    /// by the update function during processing of the event. In the mean time, the
    /// transducer can receive and process other events, but the caller is suspended until
    /// the effect task triggered by this event has completed.
    ///
    /// The caller hops to the `@MainActor` for the duration of the call. Because the
    /// `@MainActor` is a global, app-lifetime executor, the continuation is always
    /// resumed — no cancellation handler is needed.
    ///
    /// - Note: If the calling `Task` is cancelled while suspended,
    ///   `request` continues to wait until the effect chain settles.
    /// - Parameter event: The event to send into the runtime.
    /// - Throws: ``RuntimeUnavailable`` when the runtime cannot accept the request,
    ///   or `CancellationError` if accepted work is later cancelled.
    /// - Returns: The terminal `Output?` value produced by the settled effect chain.
    ///
    /// For usage patterns including `.refreshable`, `task(id:)`, and testing,
    /// see <doc:BridgingEventDrivenAndImperative>.
    @discardableResult
    public func request(
        _ event: Event
    ) async throws-> Output? where Output: Sendable, Event: Sendable {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    try await _send(event, self, continuation)
                } catch {
                    continuation.resume(throwing: runtimeBoundaryError(for: error))
                }
            }
        }
    }
    
    /// Convenience call-as-function syntax for ``post(_:)``.
    ///
    /// - Parameter event: The event to enqueue into the runtime.
    /// - Throws: Any error that ``post(_:)`` would throw for the same event.
    @inline(__always)
    public func callAsFunction(_ event: sending Event) throws {
        try post(event)
    }
}


extension EffectViewInput: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id
    }
}
