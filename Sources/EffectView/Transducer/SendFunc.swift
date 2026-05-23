/// Low-level runtime handle for routing events and control messages.
///
/// Most feature code should use higher-level entry points such as
/// ``EffectView/Input-swift.struct`` or ``EffectObservable/Input-swift.struct``.
public struct Send<Event, Input, Output>
where Input: TransducerInput<Event, Output> & Sendable {
    typealias TaggedEvent = EffectView::TaggedEvent<Event>
    typealias SendFunc = (isolated any Actor, Event, Input?, Continuation<Output>?) async throws -> Void
    typealias ControlFunc = (isolated any Actor, ControlEvent) throws -> Void

    let send: SendFunc
    let control: ControlFunc

    init(send: @escaping SendFunc, control: @escaping ControlFunc) {
        self.send = send
        self.control = control
    }

    /// Sends `event` through the runtime using the provided `input` handle.
    ///
    /// - Parameters:
    ///   - systemActor: The actor isolation that owns the runtime.
    ///   - event: The event to send into the runtime.
    ///   - input: The input handle forwarded into effect execution.
    ///   - continuation: An optional request continuation to resume when the chain settles.
    /// - Throws: Any runtime error raised while processing the event.
    @inline(__always)
    public func callAsFunction(
        systemActor: isolated any Actor = #isolation,
        _ event: Event,
        input: Input,
        continuation: Continuation<Output>? = nil
    ) async throws {
        try await send(systemActor, event, input, continuation)
    }

    func control(
        systemActor: isolated any Actor = #isolation,
        _ controlEvent: ControlEvent
    ) throws {
        try control(systemActor, controlEvent)
    }
}

extension Transducer where Effect == TransducerEffect<Event, Env, Output>, Env: Sendable, Output: Sendable {
    
    /// Creates the low-level `Send` handle used by runtime hosts.
    /// NOTE: the implementation may work for global actors - but there could be issues with
    /// actor instances since the compute function captures the instance in the closure.
    ///
    /// - Parameters:
    ///   - systemActor: The actor isolation that owns the runtime.
    ///   - input: The `TransducerInput` type to feed into effect execution.
    ///   - storage: The mutable state storage to reduce events against.
    ///   - env: The dependency environment captured for runtime work.
    /// - Returns: The low-level send handle used to route events and control messages.
    public static func makeSend<Input: TransducerInput<Event, Output> & Sendable, S: Storage>(
        systemActor: isolated any Actor = #isolation,
        with input: Input.Type = Input.self,
        storage: S,
        env: Env
    ) -> Send<Event, Input, Output>
    where S.Value == State
    {
        typealias SendFunc = Send<Event, Input, Output>.SendFunc
        typealias ControlFunc = Send<Event, Input, Output>.ControlFunc
        
        // Important: a system error is initially created by an operation or
        // action when it throws back an error. This error will be caught by
        // the EffectManager and then sent through the callback function.
        // The callback should map it to a control event and send it into the
        // transducer. The transducer then throws in the compute function.
        let taskManager = TaskManager<Output>()
        let gate = ComputeGate()
        let sendFunc: SendFunc = { isolator, event, input, continuation in
            precondition(systemActor === isolator)
            
            await gate.enter(systemActor: isolator)
            defer { gate.leave(systemActor: isolator) }
            
            try await compute(
                systemActor: isolator,
                event: event,
                continuation: continuation,
                storage: storage,
                taskManager: taskManager,
                input: input,
                env: env
            )
        }
        
        let controlFunc: ControlFunc = { isolator, controlEvent in
            precondition(systemActor === isolator)
            
            try control(
                systemActor: isolator,
                controlEvent: controlEvent,
                storage: storage,
                taskManager: taskManager
            )
        }

        let send = Send(send: sendFunc, control: controlFunc)
        
        taskManager.systemErrorCallback = { systemError in
            // TaskManager clears this callback when it latches a system error,
            // breaking the send/taskManager retain cycle during teardown.
            try? send.control(systemActor: systemActor, .systemError(systemError))
        }
        
        return send
    }
    
}

final class ComputeGate {
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter(
        systemActor: isolated any Actor = #isolation
    ) async {
        if !active {
            active = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func leave(
        systemActor: isolated any Actor = #isolation
    ) {
        if waiters.isEmpty {
            active = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

// In order to support a "failing" Actor, we need to wrap the Send function
// into an async "run" function. `run` could use withCheckedThrowingContinuation
// and pass the continuation into the compute function. With control events,
// we can resume the continuation. Then, the async throwing run function can
// be put into a Task. `run` also has a task cancellation handler installed which
// sends a control event to the actor, so that the transducer can cancel and
// terminate.
