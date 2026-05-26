
/// A handle for feeding events back into a transducer runtime.
///
/// `TransducerInput` has two dispatch styles:
///
/// - ``post(_:)`` sends an event without awaiting a result.
/// - ``request(_:)`` suspends until the triggered effect chain settles and returns
///   the terminal `Output?` value, if any.
///
/// When multiple `request` calls overlap and eventually drive a named task with the
/// same identifier, the task's ``TaskExecutionOption`` decides how the runtime treats
/// the active task for that identifier:
///
/// - `.subscribe`: keep the running task and add the new waiter to it.
/// - `.switchToLatest`: cancel the running task, start a fresh one, and move all
///   current waiters for that identifier onto the replacement task.
///
/// Equal task identifiers therefore mean more than "same cancellation key": they
/// declare the same logical in-flight work. Overlapping waiters for one identifier
/// must converge to one current result or one current error.
public protocol TransducerInput<Event, Output> {
    associatedtype Event
    associatedtype Output
    
    /// Sends `event` without awaiting a result.
    ///
    /// If `post` throws, that failure is local to the call site. It only becomes a
    /// critical runtime error if the caller lets it escape from inside an effect
    /// closure and the error is thereby fed back into the system.
    ///
    /// - Parameter event: The event to enqueue into the runtime.
    /// - Throws: A runtime entry failure if the implementation cannot accept the event.
    func post(_ event: sending Event) throws
    
    /// Sends `event` and suspends until the resulting effect chain settles.
    ///
    /// If the chain reaches a named task, overlapping waiters for the same task
    /// identifier are coalesced according to that task's ``TaskExecutionOption``.
    /// The caller is waiting for the current active task for that identifier, not
    /// necessarily for the first physical task instance that was started.
    ///
    /// - Parameter event: The event to send into the runtime.
    /// - Throws: A runtime entry failure if the request cannot start, or a later
    ///   cancellation or runtime failure while the request is in flight.
    @discardableResult
    func request(_ event: Event) async throws -> Output?
}

extension TransducerInput {
    
    /// Convenience call-as-function syntax for ``post(_:)``.
    ///
    /// - Parameter event: The event to enqueue into the runtime.
    /// - Throws: Any error that ``post(_:)`` would throw for the same event.
    @inline(__always)
    public func callAsFunction(_ event: sending Event) throws {
        try post(event)
    }
}
