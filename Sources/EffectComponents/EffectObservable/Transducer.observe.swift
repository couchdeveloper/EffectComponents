import Foundation
import Mutex
import Observation

// MARK: - Transducer.observe

extension Transducer where Effect == TransducerEffect<Event, Env, Output> {

    /// Observes a key path on an `@Observable` object resolved from the environment.
    ///
    /// The handler is invoked with the **initial value** immediately, then again on every
    /// subsequent change, until the task is cancelled or the object is deallocated.
    ///
    /// The object is resolved from the environment inside the task, so the effect captures
    /// only a key path rather than the object itself. Use ``Input/request(_:)`` in the
    /// handler so the loop waits for the view to settle before advancing:
    ///
    /// ```swift
    /// // update:
    /// case .start:
    ///     return .observe(
    ///         \.store, keyPath: \.count
    ///     ) { input, count in
    ///         await input.request(.countChanged(count))
    ///     }
    /// ```
    ///
    /// The named task (`"observe"` by default) is cancelled automatically when the view
    /// disappears, or immediately when `update` returns `cancel(name)`.
    ///
    /// - Parameters:
    ///   - envKeyPath: Key path from `Env` to the `@Observable` object. The object is held
    ///     weakly inside the task; the loop exits when it is deallocated.
    ///   - keyPath: The property on the object to observe.
    ///   - id: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - handler: Called with `input` and the current value on the initial read and on
    ///     every subsequent change. `async` — use `await input.request(…)` to wait for the
    ///     view to settle before the next observation cycle.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
    public static func observe<Object, Value>(
        _ envKeyPath: KeyPath<Env, Object>,
        keyPath: KeyPath<Object, Value>,
        id: TaskIdentifier? = "observe",
        priority: TaskPriority? = nil,
        handler: @escaping @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Value) async -> Void
    ) -> Effect
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        let envKeyPathBox = SendableKeyPath(keyPath: envKeyPath)
        return task(id: id, priority: priority) { input, env in
            do {
                let weakObject = WeakObject(object: env[keyPath: envKeyPathBox.keyPath])
                await handler(input, try observedValue(weakObject, keyPath: box))
                while true {
                    try await _waitForObservationChange(weakObject, keyPath: box)
                    await handler(input, try observedValue(weakObject, keyPath: box))
                }
            } catch is CancellationError {
                // Transducer logic has cancelled. Do not rethrow.
                // Expected termination path for explicit cancel(name) or view teardown.
            } catch is ObservationTerminationError {
                // IFF we would rethrow the error, the update function is responsible
                // to catch and handle it, or otherwise it becomes a critical
                // system error.
                
                // For now we end the observation quietly.
            } catch {
                // IFF we would rethrow the error, the update function is responsible
                // to catch and handle it, or otherwise it becomes a critical
                // system error.
                assertionFailure("Unexpected observation failure: \(error)")
            }
            return nil
        }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
    /// Observes an environment-resolved key path and runs the callback on the host actor.
    ///
    /// Semantics match the `handler`-based overload, but `isolatedHandler` receives the
    /// current host actor isolation explicitly.
    ///
    /// - Parameters:
    ///   - systemActor: The host actor isolation forwarded into `isolatedHandler`.
    ///   - envKeyPath: Key path from `Env` to the `@Observable` object.
    ///   - keyPath: The property on the object to observe.
    ///   - id: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - isolatedHandler: Called with `input`, the current value, and the host actor.
    public static func observe<Object, Value>(
        systemActor: isolated (any Actor)? = #isolation,
        _ envKeyPath: KeyPath<Env, Object>,
        keyPath: KeyPath<Object, Value>,
        id: TaskIdentifier? = "observe",
        priority: TaskPriority? = nil,
        isolatedHandler: @escaping (any TransducerInput<Event, Output>, Value, isolated any Actor) async -> Void
    ) -> Effect
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        let envKeyPathBox = SendableKeyPath(keyPath: envKeyPath)
        return task(id: id, priority: priority) { input, env, isolation in
            do {
                precondition(
                    systemActor != nil && systemActor === isolation,
                    "observe(isolatedOperation:) requires a non-nil matching system actor. Actor hosts must provide isolation. Expected \(String(describing: systemActor)), got \(isolation)."
                )
                let weakObject = WeakObject(object: env[keyPath: envKeyPathBox.keyPath])
                await isolatedHandler(input, try observedValue(weakObject, keyPath: box), isolation)
                while true {
                    try await _waitForObservationChange(weakObject, keyPath: box)
                    await isolatedHandler(input, try observedValue(weakObject, keyPath: box), isolation)
                }
            }
            catch is CancellationError {
                // Expected termination path for explicit cancel(name) or view teardown.
            } catch is ObservationTerminationError {
                // Observed object deallocated; end the observation quietly.
            } catch {
                assertionFailure("Unexpected observation failure: \(error)")
            }
            return nil
        }
    }

    /// Observes a key path on a directly provided `@Observable` object.
    ///
    /// The handler is invoked with the **initial value** immediately, then again on every
    /// subsequent change, until the task is cancelled or the object is deallocated.
    ///
    /// The `input` parameter gives the handler the same three dispatch strategies
    /// (``Input/post(_:)``, ``Input/send(_:)``, ``Input/request(_:)``) available in any
    /// other effect. For observation you will typically want ``Input/request(_:)`` so the loop
    /// waits for the EffectView to process each change before advancing to the next one:
    ///
    /// ```swift
    /// // update:
    /// case .storeReceived(let store):
    ///     return .observe(
    ///         store, keyPath: \.count
    ///     ) { input, count in
    ///         await input.request(.countChanged(count))
    ///     }
    /// ```
    ///
    /// The named task (`"observe"` by default) is cancelled automatically when the view
    /// disappears, or immediately when `update` returns `cancel(name)`.
    ///
    /// - Parameters:
    ///   - object: The `@Observable` object to watch. Held weakly inside the task so the
    ///     effect does not extend the object's lifetime. The loop exits when `object` is
    ///     deallocated.
    ///   - keyPath: The property to observe.
    ///   - id: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - operation: Called with `input` and the current value on the initial read and on
    ///     every subsequent change. `async` — use `await input.request(…)` to wait for the
    ///     view to settle before the next observation cycle.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
    public static func observe<Object, Value>(
        _ object: Object,
        keyPath: KeyPath<Object, Value>,
        id: TaskIdentifier? = "observe",
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable @isolated(any) (any TransducerInput<Event, Output> & Sendable, Value) async -> Void
    ) -> Effect
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        let weakObject = WeakObject(object: object)
        return task(id: id, priority: priority) { input, env in
            do {
                await operation(input, try observedValue(weakObject, keyPath: box))
                while true {
                    try await _waitForObservationChange(weakObject, keyPath: box)
                    await operation(input, try observedValue(weakObject, keyPath: box))
                }
            } catch is CancellationError {
                // Expected termination path for explicit cancel(name) or view teardown.
            } catch is ObservationTerminationError {
                // Observed object deallocated; end the observation quietly.
            } catch {
                assertionFailure("Unexpected observation failure: \(error)")
            }
            return nil
        }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
    /// Observes a directly provided key path and runs the callback on the host actor.
    ///
    /// Semantics match the `operation`-based overload, but `isolatedOperation` receives the
    /// current host actor isolation explicitly.
    ///
    /// - Parameters:
    ///   - systemActor: The host actor isolation forwarded into `isolatedOperation`.
    ///   - object: The `@Observable` object to watch.
    ///   - keyPath: The property to observe.
    ///   - id: Optional name for the underlying task. Defaults to `"observe"`.
    ///   - priority: Optional `TaskPriority` for the underlying task.
    ///   - isolatedOperation: Called with `input`, the current value, and the host actor.
    public static func observe<Object, Value>(
        systemActor: isolated (any Actor)? = #isolation,
        _ object: Object,
        keyPath: KeyPath<Object, Value>,
        id: TaskIdentifier? = "observe",
        priority: TaskPriority? = nil,
        isolatedOperation: @escaping (any TransducerInput<Event, Output>, Value, isolated any Actor) async -> Void
    ) -> Effect
    where Object: Observable & AnyObject & Sendable, Value: Sendable
    {
        let box = SendableKeyPath(keyPath: keyPath)
        let weakObject = WeakObject(object: object)
        return task(id: id, priority: priority) { input, env, isolation in
            do {
                precondition(
                    systemActor != nil && systemActor === isolation,
                    "observe(isolatedOperation:) requires a non-nil matching system actor. Actor hosts must provide isolation. Expected \(String(describing: systemActor)), got \(isolation)."
                )
                await isolatedOperation(input, try observedValue(weakObject, keyPath: box), isolation)
                while true {
                    try await _waitForObservationChange(weakObject, keyPath: box)
                    await isolatedOperation(input, try observedValue(weakObject, keyPath: box), isolation)
                }
            } catch is CancellationError {
                // Expected termination path for explicit cancel(name) or view teardown.
            } catch is ObservationTerminationError {
                // Observed object deallocated; end the observation quietly.
            } catch {
                assertionFailure("Unexpected observation failure: \(error)")
            }
            return nil
        }
    }

}

// MARK: - Internal helpers

/// A minimal `@unchecked Sendable` box for `KeyPath`.
///
/// `KeyPath` is a value type with no mutable state — it is intrinsically safe to share
/// across concurrency domains. This wrapper makes that explicit so key path values can be
/// captured in `@Sendable` closures without requiring `SE-0418` (`InferSendableFromCaptures`)
/// at every call site.
private struct SendableKeyPath<Root, Value>: @unchecked Sendable {
    let keyPath: KeyPath<Root, Value>
}

private final class ObservationContinuationBox: @unchecked Sendable {
    private enum State {
        case pending(CheckedContinuation<Void, Error>?)
        case resolved(Result<Void, Error>)
    }

    private let state = Mutex(State.pending(nil))

    init() {}

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let resultToResume: Result<Void, Error>? = state.withLock { state in
            switch state {
            case .pending(nil):
                state = .pending(continuation)
                return nil
            case .pending(.some):
                fatalError("Observation continuation installed more than once")
            case .resolved(let result):
                return result
            }
        }

        if let resultToResume {
            resumeContinuation(continuation, with: resultToResume)
        }
    }

    func resume() {
        resolve(with: .success(()))
    }

    func resume(throwing error: Error) {
        resolve(with: .failure(error))
    }

    private func resolve(with result: Result<Void, Error>) {
        let continuationToResume = state.withLock { state in
            switch state {
            case .pending(let continuation):
                state = .resolved(result)
                return continuation
            case .resolved:
                return nil
            }
        }

        if let continuationToResume {
            resumeContinuation(continuationToResume, with: result)
        }
    }
}

private struct WeakObject<Object: AnyObject>: @unchecked Sendable where Object: Sendable {
    weak var object: Object?
}

private enum ObservationTerminationError: Error {
    case deallocated
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
@inline(__always)
private func observedValue<Object, Value>(
    _ weakObject: WeakObject<Object>,
    keyPath box: SendableKeyPath<Object, Value>
) throws -> Value where Object: Observable & AnyObject & Sendable, Value: Sendable {
    guard let object = weakObject.object else {
        throw ObservationTerminationError.deallocated
    }
    return object[keyPath: box.keyPath]
}

@inline(__always)
private func resumeContinuation(
    _ continuation: CheckedContinuation<Void, Error>,
    with result: Result<Void, Error>
) {
    switch result {
    case .success:
        continuation.resume()
    case .failure(let error):
        continuation.resume(throwing: error)
    }
}


/// Observes a key path on an `@Observable` object, calling `handler`
/// with each new value until the task is cancelled or `object` is
/// deallocated.
///
/// - Parameters:
///   - systemActor: The actor isolation used to deliver observed values to `handler`.
///   - object: The observable object to watch.
///   - keyPath: The property to observe on `object`.
///   - handler: The async callback invoked with each observed value.
/// - Throws: If observation is cancelled or the object becomes unavailable before
///   the next value can be delivered.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
public func observeKeyPath<Object, Value>(
    systemActor: isolated any Actor = #isolation,
    _ object: Object,
    keyPath: KeyPath<Object, Value>,
    handler: @escaping (isolated any Actor, Value) async -> Void
) async throws where Object: Observable & AnyObject & Sendable, Value: Sendable {
    let box = SendableKeyPath(keyPath: keyPath)
    let weakObject = WeakObject(object: object)

    try await observeWeakKeyPath(systemActor: systemActor, weakObject, keyPath: box, isolatedHandler: handler)
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
private func observeWeakKeyPath<Object, Value>(
    systemActor: isolated any Actor = #isolation,
    _ weakObject: WeakObject<Object>,
    keyPath box: SendableKeyPath<Object, Value>,
    isolatedHandler: @escaping (isolated any Actor, Value) async -> Void
) async throws where Object: Observable & AnyObject & Sendable, Value: Sendable {
    let initialValue = try observedValue(weakObject, keyPath: box)

    // Seed the initial value — withObservationTracking only fires on *changes*.
    await isolatedHandler(systemActor, initialValue)

    while true {
        try await _waitForObservationChange(weakObject, keyPath: box)
        await isolatedHandler(systemActor, try observedValue(weakObject, keyPath: box))
    }
}

/// Legacy one-shot waiter for `observeKeyPath` on macOS < 26.
///
/// `onChange` fires *before* the new value is committed and on an arbitrary thread, so a
/// child `Task` hops back onto `systemActor` before resuming the suspended observer.
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *)
private func _waitForObservationChange<Object, Value>(
    _ weakObject: WeakObject<Object>,
    keyPath box: SendableKeyPath<Object, Value>,
) async throws where Object: Observable & AnyObject & Sendable, Value: Sendable {
    let continuationBox = ObservationContinuationBox()

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuationBox.install(continuation)

            func installObservation() {
                guard weakObject.object != nil else {
                    continuationBox.resume(throwing: ObservationTerminationError.deallocated)
                    return
                }
                withObservationTracking(
                    { _ = weakObject.object?[keyPath: box.keyPath] },
                    onChange: {
                        Task {
                            continuationBox.resume()
                        }
                    }
                )
            }

            installObservation()
        }
    } onCancel: {
        continuationBox.resume(throwing: CancellationError())
    }
}

