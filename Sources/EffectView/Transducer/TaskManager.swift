
/// Coordinates keyed async tasks and their waiting continuations for one runtime.
///
/// `TaskManager` tracks tasks by logical identifier rather than only by task
/// instance. Equal identifiers mean equal in-flight work. When a new waiter
/// arrives for an identifier that already has an active task, the manager uses
/// ``TaskExecutionOption`` to decide whether the waiter subscribes to the
/// existing task or replaces it with a fresh task.
///
/// The manager also defines the runtime's hard-stop semantics. Once
/// ``cancel(with:)`` begins cancellation, the manager rejects new tasks and
/// cancels tracked work. Graceful teardown is intentionally not part of this
/// type. A controlled shutdown must be modeled in transducer state and event
/// flow instead.
final class TaskManager<Output: Sendable> {
    
    /// A waiter suspended on a task result managed by this instance.
    typealias Continuation = CheckedContinuation<Output?, Error>
    
    /// Describes whether the manager is accepting work or shutting down.
    enum State {
        /// The manager accepts new tasks and waiters.
        case active
        /// Cancellation has begun and the manager has latched an optional error.
        case cancelling(error: Swift.Error? = nil)
        /// Cancellation has fully completed and the optional error remains latched.
        case cancelled(error: Swift.Error? = nil)
    }
    
    private var tasks: Dictionary<TaskKey, TaskValue> = [:]
    private var taskId: Int = 0 // a monotonic increasing integer used as a unique identifier for a task.
    private(set) var state: State = .active
    
    var systemErrorCallback: ((any Swift.Error) async -> Void)? = nil
    
    /// Optional callback for surfacing a fatal system error back to the runtime owner.
    init(systemErrorCallback: ((any Swift.Error) async -> Void)? = nil) {
        self.systemErrorCallback = systemErrorCallback
        #if DEBUG
        print("EffectManager: init")
        #endif
    }
    
    deinit {
        #if DEBUG
        print("EffectManager: deinit")
        #endif
        let shutdownError = latchedShutdownError
        tasks.values.forEach { taskValue in
            var taskValue = taskValue
            taskValue.cancel(with: shutdownError)
        }
    }
    
    /// Throws if the manager is no longer accepting work.
    ///
    /// Callers typically use this as a boundary check before entering the main
    /// runtime loop. When the manager has latched a concrete shutdown error,
    /// that error is rethrown. Otherwise `RuntimeUnavailable.cancelled` is
    /// thrown.
    ///
    /// - Throws: The latched shutdown error, or `RuntimeUnavailable.cancelled`
    ///   when cancellation happened without a more specific reason.
    @inline(__always)
    func checkCancellation() throws {
        switch state {
            case .active: break
            case .cancelling(let error), .cancelled(let error):
            if let error {
                throw error
            } else {
                throw RuntimeError.cancelled
            }
        }
    }

    /// Starts hard cancellation of the manager and its tracked tasks.
    ///
    /// The first call latches `error`, transitions the manager out of the
    /// active state, clears ``systemErrorCallback``, and cancels all tracked
    /// tasks. Later calls are ignored.
    ///
    /// - Parameter error: An optional shutdown reason to latch for later
    ///   ``checkCancellation()`` calls.
    func cancel(with error: (any Swift.Error)? = nil) {
        guard case .active = self.state else {
            return
        }
        self.state = .cancelling(error: error)
        // Break the send/taskManager retain cycle once the runtime has irreversibly failed.
        systemErrorCallback = nil

        for taskKey in Array(tasks.keys) {
            tasks[taskKey]?.cancel(with: error)
        }
        if tasks.isEmpty {
            state = .cancelled(error: error)
        }
    }

    private var latchedShutdownError: any Swift.Error {
        switch state {
        case .active:
            return RuntimeError.cancelled
        case .cancelling(let error), .cancelled(let error):
            return error ?? RuntimeError.cancelled
        }
    }

    /// Cancels the tracked task for `identifier`, if one exists.
    ///
    /// All waiters currently attached to that task are resumed with
    /// `CancellationError()`.
    ///
    /// - Parameter identifier: The logical identifier of the task to cancel.
    /// - Returns: `true` if an active tracked task was found and cancelled.
    @discardableResult
    func cancelTasks(
        systemActor: isolated any Actor = #isolation,
        with identifier: TaskIdentifier
    ) -> Bool {
        let taskKey = TaskKey(identifier)
        if var taskValue = tasks[taskKey] {
            if !taskValue.task.isCancelled {
                taskValue.cancel()
                tasks[taskKey] = taskValue
                #if DEBUG
                print("EffectManager cancelled task: \(identifier)-\(tasks[taskKey]!.id)")
                #endif
                return true
            } else {
                #if DEBUG
                print("EffectManager did not cancel task with identifier \"\(identifier)\" - because it is already cancelled")
                #endif
                return false
            }
        } else {
            #if DEBUG
            print("EffectManager could not cancel task with identifier \"\(identifier)\" - not in tasks")
            #endif
            return false
        }
    }
    
    /// Adds a task or waiter to the manager.
    ///
    /// If the manager is still active, the task identified by `identifier` is
    /// either reused or replaced according to `option`. When `continuation` is
    /// non-`nil`, it is attached to the active task chosen for that identifier.
    ///
    /// If the manager is no longer active, `continuation` is resumed with the
    /// latched shutdown error, or `RuntimeUnavailable.cancelled` when shutdown
    /// happened without a more specific reason, and no new task is started.
    ///
    /// - Parameters:
    ///   - systemActor: The isolation the system is executing on.
    ///   - identifier: The logical task identity. Equal identifiers mean equal
    ///     overlapping work.
    ///   - option: Decides whether a new waiter reuses the active task or replaces it.
    ///   - continuation: If not `nil`, a waiter which will be resumed when the current
    ///     active task for this identifier completes.
    ///   - priority: The priority of the operation task.
    ///   - isolatedOperation: The operation to perform.
    func addTask(
        systemActor: isolated any Actor = #isolation,
        with identifier: TaskIdentifier? = nil,
        option: TaskExecutionOption = .switchToLatest,
        continuation: Continuation?,
        priority: TaskPriority? = nil,
        isolatedOperation: @escaping (isolated any Actor) async throws -> Output?
    ) {
        // TODO: check if this should be better a precondition
        guard case .active = state else {
            if let continuation {
                continuation.resume(throwing: latchedShutdownError)
            }
            return
        }
        switch option {
        case .switchToLatest:
            var continuations: [Continuation] = []
            if let taskIdentifier = identifier {
                continuations = cancelForReplacement(identifier: taskIdentifier)
            }
            if let continuation {
                continuations.append(continuation)
            }
            addNewTask(
                identifier: identifier,
                continuations: continuations,
                priority: priority,
                isolatedOperation: isolatedOperation
            )
            
        case .subscribe:
            if let identifier,
               let continuation,
               var taskValue = tasks[TaskKey(identifier)] {
                // add subscriber (aka waiter) to the existing tracked task, even if it
                // has already been cancelled but has not completed yet.
                taskValue.subscribe(continuation: continuation)
                tasks[TaskKey(identifier)] = taskValue
            } else {
                let continuations = continuation.map { [$0] } ?? []
                addNewTask(
                    identifier: identifier,
                    continuations: continuations,
                    priority: priority,
                    isolatedOperation: isolatedOperation
                )
            }
        }
    }

    /// Cancels the current task for replacement and returns its waiter set.
    ///
    /// `.switchToLatest` replaces the task instance but preserves the waiter set
    /// by moving those continuations onto the replacement task.
    @discardableResult
    private func cancelForReplacement(identifier: TaskIdentifier) -> [Continuation] {
        let taskKey = TaskKey(identifier)
        guard var taskValue = tasks[taskKey] else {
            return []
        }
        // Keep the waiter set; `.switchToLatest` replaces the task instance, not the waiters.
        let continuations = taskValue.cancelForReplacement()
        tasks[taskKey] = taskValue
        #if DEBUG
        print("EffectManager cancelled task for replacement: \(identifier)-\(taskValue.id)")
        #endif
        return continuations
    }
    
    /// Inserts a fresh tracked task under `identifier`.
    ///
    /// The new task captures `systemActor`, runs `isolatedOperation`, and then
    /// either resumes the attached waiters with the operation result or begins
    /// manager cancellation when the operation fails with a non-task-cancellation
    /// error.
    private func addNewTask(
        systemActor: isolated any Actor = #isolation,
        identifier: TaskIdentifier?,
        continuations: [Continuation],
        priority: TaskPriority?,
        isolatedOperation: @escaping (isolated any Actor) async throws -> Output?
    ) {
        let taskKey: TaskKey
        let id = taskId
        if let identifier = identifier {
            taskKey = TaskKey(identifier)
        } else {
            taskKey = TaskKey.makeAnon(with: id)
        }
        // CAUTION: `systemActor` is captured *strongly*!. In cases, where the
        // systemActor keeps a strong reference to `self`, self will never be
        // deallocated before all tasks are finished, because the captured
        // `systemActor` establishes a reference cycle - until after the task
        // finishes. This is important to know when implementing an "FSM Effect
        // Actor" based on Swift Actors. That is, a proper implementation of an
        // "FSM Effect Actor" should always have a `cancel()` method which cancels
        // all running tasks and additionally prevents enqueueing new ones.
        let task = Task(name: taskKey.string, priority: priority) { [weak self] in
            _ = systemActor
            let result: Result<Output?, Error>
            do {
                let output = try await isolatedOperation(systemActor)
                result = .success(output)
            } catch {
                result = .failure(error)
            }
            switch result {
            case .failure(let error):
                if error is CancellationError && Task.isCancelled {
                    self?.finish(taskKey: taskKey, id: id, result: result)
                } else {
                    if let systemErrorCallback = self?.systemErrorCallback {
                        await systemErrorCallback(error)
                    } else {
                        self?.cancel(with: error)
                    }
                    self?.complete(taskKey: taskKey, id: id)
                }
            case .success:
                self?.finish(taskKey: taskKey, id: id, result: result)
            }
        }
        
        let taskValue = TaskValue(id: id, task: task, continuations: continuations)
        taskId += 1
        tasks[taskKey] = taskValue
        
        #if DEBUG
        print("EffectManager added Task: \(taskKey)-\(taskValue.id)")
        #endif
    }

    /// Resumes all waiters for the matching task and removes it from tracking.
    private func finish(taskKey: TaskKey, id: Int, result: Result<Output?, Error>) {
        if var taskValue = tasks[taskKey], taskValue.id == id {
            taskValue.resume(with: result)
            tasks[taskKey] = taskValue
        }
        complete(taskKey: taskKey, id: id)
    }
    
    /// Removes the tracked task if `id` still matches the current entry.
    private func complete(taskKey: TaskKey, id: Int) {
        if let taskValue = tasks[taskKey], taskValue.id == id {
            precondition(taskValue.continuations.isEmpty)
            tasks[taskKey] = nil
        } else {
            // Currently, with TaskKey being hashed on the identifier,
            // this can happen, when a subsequent task cancels the previous
            // one (aka `switchToLatest`), and the previous task has not
            // been completed (and removed) *before* the new task has been
            // inserted into the dictionary with the *same* key. When the previous
            // task eventually completes, there is no entry with its `id`
            // anymore.
            /* nothing */
        }
        if tasks.isEmpty, case .cancelling(let error) = state {
            state = .cancelled(error: error)
        }
        #if DEBUG
        print("EffectManager task completed: \(taskKey.string)-\(id)")
        #endif
    }
    
}

extension TaskManager {
    
    /// The dictionary key used to track a logical task.
    struct TaskKey: Hashable, Equatable, CustomStringConvertible {
        init(_ identifier: TaskIdentifier) {
            self.identifier = identifier
        }
        
        static func makeAnon(with taskId: Int) -> TaskKey {
            return .init(TaskIdentifier("__\(taskId)"))
        }

        let identifier: TaskIdentifier?

        var description: String { string }
        var string: String { "\(identifier, default: "__")" }
    }
    
    /// The mutable tracked value for one logical task entry.
    struct TaskValue {
        let id: Int // unique task id
        let task: Task<Void, Never>
        var continuations: [Continuation]
        
        init(id: Int, task: Task<Void, Never>, continuations: [Continuation]) {
            self.id = id
            self.task = task
            self.continuations = continuations
        }
        
        /// Cancels the task and fails all current waiters with `error`, or with
        /// `CancellationError()` when no more specific reason is available.
        mutating func cancel(with error: (any Swift.Error)? = nil) {
            task.cancel()
            for continuation in continuations {
                continuation.resume(throwing: error ?? CancellationError())
            }
            continuations = []
        }
        
        /// Completes all current waiters with the finished task result.
        mutating func resume(with result: Result<Output?, Error>) {
            for continuation in continuations {
                switch result {
                    case .failure(let error):
                    continuation.resume(throwing: error)
                case .success(let output):
                    continuation.resume(returning: output)
                }
            }
            continuations = []
        }
        
        /// Attaches a new waiter to the tracked task.
        mutating func subscribe(continuation: Continuation) {
            continuations.append(continuation)
        }

        /// Cancels the task for `.switchToLatest` while preserving its waiters.
        mutating func cancelForReplacement() -> [Continuation] {
            task.cancel()
            let continuations = continuations
            self.continuations = []
            return continuations
        }
    }
    
}

/// A typed logical identifier for managed tasks.
///
/// Equal `TaskIdentifier` values declare the same in-flight work. The
/// task manager uses that identity to decide whether a new task request should
/// subscribe to existing work or replace it.
public struct TaskIdentifier: @unchecked Sendable, Hashable {
    private let wrapped: AnyHashable

    /// Creates an identifier from any hashable, sendable value.
    ///
    /// - Parameter wrapped: The logical identifier value to wrap.
    public init(_ wrapped: some Hashable & Sendable) {
        self.wrapped = .init(wrapped)
    }
}

extension TaskIdentifier: ExpressibleByStringLiteral {
    /// Creates an identifier from a string literal.
    ///
    /// - Parameter stringLiteral: The string value to wrap as an identifier.
    public init(stringLiteral: String) {
        self.init(stringLiteral)
    }
}

extension TaskIdentifier: ExpressibleByIntegerLiteral {
    /// Creates an identifier from an integer literal.
    ///
    /// - Parameter value: The integer value to wrap as an identifier.
    public init(integerLiteral value: IntegerLiteralType) {
        self.init(value)
    }
}

extension TaskIdentifier: ExpressibleByStringInterpolation {}


extension TaskIdentifier: CustomStringConvertible {
    /// Human-readable representation of the identifier.
    public var description: String { string }

    /// The identifier rendered as a string.
    public var string: String { wrapped.description }
}


/// Controls how the runtime handles a new request for an identifier that already has
/// an active task.
///
/// Equal task identifiers declare the same logical in-flight work. The option decides
/// whether the runtime reuses the current task instance or replaces it with a fresh one.
///
/// A later request only competes with work that is still active for the same logical
/// identifier. Once the tracked task has completed, the next request starts fresh
/// regardless of which option was used previously.
public enum TaskExecutionOption {
    /// Cancel the running task for this identifier, start a fresh task, and attach all
    /// current waiters plus the new waiter to the replacement task.
    ///
    /// - > Caution: `switchToLatest` replaces the physical task instance but preserves
    ///   waiter ownership. Existing waiters do not fail merely because a replacement
    ///   starts; they move to the new current task for the same identifier.
    case switchToLatest

    /// Keep the running task for this identifier and add the new waiter to it.
    ///
    /// Later callers share the current logical work and receive the same terminal
    /// result or failure as the active task for that identifier.
    case subscribe
}
