extension Transducer where Effect == TransducerEffect<Event, Env, Output>, Env: Sendable, Output: Sendable {
    
    /// Runs the transducer runtime directly with an explicit low-level send handle.
    ///
    /// This API is intended as the low-level entry point beneath higher-level hosts such
    /// as ``EffectView`` and ``EffectObservable``.
    ///
    /// - Warning: This entry point is currently a stub and always throws
    ///   ``RunError/notImplemented``.
    /// - Parameters:
    ///   - systemActor: The actor isolation that owns the runtime.
    ///   - send: The low-level send handle used to route events and control messages.
    ///   - initialState: The starting state for the runtime.
    ///   - input: The input handle to expose to effect execution.
    /// - Throws: ``RunError/notImplemented``.
    /// - Returns: The terminal `Output?` value once the runtime settles.
    @discardableResult
    public static func run<Input: TransducerInput<Event, Output> & Sendable>(
        systemActor: isolated any Actor = #isolation,
        send: Send<Event, Input, Output>,
        initialState: State,
        input: Input
    ) async throws -> Output? {
        _ = send
        _ = initialState
        _ = input
        throw RunError.notImplemented
    }
}

// TODO: when implemente, remove it
/// Placeholder error for the unfinished low-level ``Transducer/run(systemActor:send:initialState:input:)`` API.
public enum RunError: Error, Sendable {
    /// The requested runtime entry point has not been implemented yet.
    case notImplemented
}

