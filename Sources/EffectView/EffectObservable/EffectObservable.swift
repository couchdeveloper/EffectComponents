import Observation

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
@MainActor
@Observable
/// Observable host for a transducer-driven runtime.
///
/// `EffectObservable` stores the current transducer `State`, exposes it
/// through Swift Observation, and provides an ``Input`` handle for sending
/// events back into the runtime from views, tasks, and callbacks.
///
/// Construct the observable once for the host view's lifetime. The runtime
/// captures `Env` at initialization, updates ``state`` only through the
/// transducer, and keeps event processing serialized on the `@MainActor`.
public final class EffectObservable<
    T: Transducer,
> where
    T.Output: Sendable,
    T.Env: Sendable,
    T.Effect == TransducerEffect<T.Event, T.Env, T.Output>,
    T.Event: Sendable
{
    public typealias State = T.State
    public typealias Event = T.Event
    public typealias Env = T.Env
    public typealias Output = T.Output
    public typealias Effect = T.Effect
    
    typealias Storage = UnownedReferenceKeyPathStorage<EffectObservable, State>
    typealias Send = EffectView::Send<Event, Input, Output>
    

    /// Current transducer state published through Swift Observation.
    internal(set) public var state: State

    @ObservationIgnored
    private var runtimeSend: Send?
    @ObservationIgnored
    nonisolated(unsafe) private var runtimeUnavailable: RuntimeUnavailable?
    @ObservationIgnored
    private var initialEvent: Event?
    @ObservationIgnored
    private var storage: Storage!
    @ObservationIgnored
    private var _input: Input!
    
        
    /// Creates an observable runtime with a captured dependency environment.
    ///
    /// Use `initialEvent` to kick off startup work after construction. The
    /// event is scheduled asynchronously; the initializer does not wait for
    /// that work to finish before returning.
    ///
    /// - Parameters:
    ///   - of: The transducer type.
    ///   - initialState: The initial value for ``state``.
    ///   - initialEvent: An optional event sent when the view first appears.
    ///   - env: Dependencies captured for the runtime lifetime.
    public init(
        of: T.Type = T.self,
        initialState: State,
        initialEvent: Event? = nil,
        env: Env
    ) {
        self.state = initialState
        self.initialEvent = initialEvent
        self.storage = .init(host: self, keyPath: \.state)
        let send = T.makeSend(
            with: Input.self,
            storage: storage,
            env: env
        )
        self._input = Input(self)
        self.runtimeSend = send
        if let event = initialEvent {
            Task {
                do {
                    try await send(event, input: _input)
                } catch {
                    print("could not process initial event: \(error)")
                    // TODO: consider sending a control event
                }
            }
        }
    }
    
    isolated deinit {
        cancel()
    }
    
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
    /// - Caution: `send` preserves ordered inline reduction. If the current event chain
    ///   reaches a long-running awaited step, the caller remains suspended until that
    ///   step yields control back to the runtime.
    ///
    /// - seealso: **Effect Operations and Actions**
    ///
    /// - Note: `send` may suspend only when it executes suspending effect actions.
    ///
    /// - Parameter event: The event that is sent into the system.
    /// - Throws: ``RuntimeUnavailable/actorCancelled`` if the runtime has already been
    ///   cancelled, ``RuntimeUnavailable/systemError`` if the runtime has latched a
    ///   critical failure, or `CancellationError` if accepted work is later cancelled.
    public func send(_ event: Event) async throws {
        try checkRuntimeAvailability()
        guard let send = runtimeSend else {
            throw RuntimeUnavailable.actorCancelled
        }
        do {
            try await send(event, input: _input)
        } catch {
            let boundaryError = runtimeBoundaryError(for: error)
            if let runtimeUnavailable = boundaryError as? RuntimeUnavailable {
                self.runtimeUnavailable = runtimeUnavailable
            }
            throw boundaryError
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
    /// - seealso: **Effect Operations and Actions**
    ///
    /// ## Effect Operations and Actions
    ///
    /// If the chain reaches a named task, overlapping waiters for the same task
    /// identifier are coalesced according to that task's ``TaskExecutionOption``.
    /// The caller is waiting for the current active task for that identifier, not
    /// necessarily for the first physical task instance that was started.
    ///
    /// A single event can trigger a cascade: an `.action` may return the next event to
    /// process immediately, which in turn may return another, and so on. The continuation
    /// is threaded through the whole chain and only resumed when the chain reaches a
    /// terminal effect — typically a `.task`, whose async operation runs to completion
    /// before `request` returns.
    ///
    /// ```
    /// event → [.action chain] → terminal effect
    ///                           ├─ .task   → Output?
    ///                           ├─ .cancel → nil
    ///                           └─ nil     → nil
    /// ```
    ///
    /// - Caution: Cancelling the caller does not immediately tear down an accepted request.
    ///   The runtime resumes the continuation only after the in-flight chain reaches a
    ///   terminal outcome or the runtime reports cancellation.
    ///
    /// - Parameter event: The event that is sent into the system.
    /// - Throws: ``RuntimeUnavailable/actorCancelled`` if the runtime has already been
    ///   cancelled, ``RuntimeUnavailable/systemError`` if the runtime has latched a
    ///   critical failure before the request can enter or while it is running, or
    ///   `CancellationError` if accepted work is later cancelled.
    /// - Returns: the `Output?` value produced by the terminal `.task` closure.
    public func request(_ event: Event) async throws -> Output? {
        // TODO: consider to to add a Task cancellation handler which sends a corresponding control event to the transducer.
        // The transducer's action on this is currently "implementation defined". It *could* have no effect on the task operation, or it *could* cancel it.
        try checkRuntimeAvailability()
        guard let send = self.runtimeSend, let input = _input else {
            throw RuntimeUnavailable.actorCancelled
        }
        return try await withCheckedThrowingContinuation { (continuation: Continuation<Output>) in
            Task {
                do {
                    try await send.send(MainActor.shared, event, input, continuation)
                } catch {
                    let boundaryError = runtimeBoundaryError(for: error)
                    if let runtimeUnavailable = boundaryError as? RuntimeUnavailable {
                        self.runtimeUnavailable = runtimeUnavailable
                    }
                    continuation.resume(throwing: boundaryError)
                }
            }
        }
    }
    
    /// Dispatch handle for sending events into this runtime.
    public var input: Input {
        _input
    }
    
    /// Immediately cancels the observable runtime.
    ///
    /// After cancellation, newly created ``input`` handles will no longer
    /// deliver events, and pending ``Input/request(_:)`` calls resolve with
    /// `nil` if they reach the cancelled runtime after teardown.
    ///
    /// This is host-level disposal, not graceful transducer shutdown. Model a
    /// gentle teardown as an event handled by the transducer itself, then call
    /// `cancel()` when the host is ready to discard the runtime.
    public func cancel() {
        cancelRuntime(with: RuntimeUnavailable.actorCancelled)
    }
    
    /// Cancels the observable runtime with a caller-provided system error.
    ///
    /// Use this when the host needs pending work to observe a specific
    /// failure at the runtime boundary rather than a generic cancellation.
    ///
    /// - Parameter error: The system-level failure to latch and broadcast.
    public func cancel(with error: any Swift.Error) {
        cancelRuntime(with: error)
    }
    
    // MARK -

    nonisolated
    func checkRuntimeAvailability() throws {
        if let runtimeUnavailable {
            throw runtimeUnavailable
        }
    }

    private func cancelRuntime(with systemError: any Swift.Error) {
        guard runtimeUnavailable == nil else {
            return
        }

        runtimeUnavailable = .actorCancelled

        guard let send = runtimeSend else {
            return
        }

        Task { @MainActor [send] in
            try? send.control(ControlEvent.systemError(systemError))
        }
    }

}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
extension EffectObservable where Env == Void {
    
    /// Creates an observable runtime with no external dependencies.
    ///
    /// - Parameters:
    ///   - of: The transducer type.
    ///   - initialState: The initial value for ``state``.
    ///   - initialEvent: An optional event sent when the view first appears.
    convenience public init(
        of transducer: T.Type = T.self,
        initialState: State,
        initialEvent: Event? = nil
    ) {
        self.init(
            of: transducer,
            initialState: initialState,
            initialEvent: initialEvent,
            env: ()
        )
    }
}

