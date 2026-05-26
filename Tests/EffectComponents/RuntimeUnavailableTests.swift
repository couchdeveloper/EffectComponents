import Testing
@testable import EffectComponents

#if canImport(Observation)

@Suite("Runtime unavailable")
@MainActor
struct RuntimeUnavailableTests {

    enum LatchedSystemError: Error, Equatable {
        case boom
    }

    enum T: Transducer {
        struct State: Equatable {}
        enum Event: Sendable { case ping }

        static func update(_ state: inout State, event: Event) -> Effect? {
            nil
        }
    }

    enum RequestCancellationTransducer: Transducer {
        struct State: Equatable {}
        enum Event: Sendable { case start }
        struct Env: Sendable {
            let started: Expectation
            let cancelled: Expectation
        }

        typealias Output = String

        static func update(_ state: inout State, event: Event) -> Effect? {
            switch event {
            case .start:
                return task(id: "work") { _, env in
                    env.started.fulfill()
                    do {
                        while true {
                            try await Task.sleep(nanoseconds: 50_000_000)
                        }
                    } catch is CancellationError {
                        env.cancelled.fulfill()
                        throw CancellationError()
                    }
                }
            }
        }

        static func output(state: State, event: Event) -> String {
            ""
        }
    }

    enum LatchedFailureTransducer: Transducer {
        struct State: Equatable {}
        enum Event: Sendable { case start }

        typealias Output = String

        static func update(_ state: inout State, event: Event) -> Effect? {
            switch event {
            case .start:
                return task(id: "work") { _, _ in
                    throw LatchedSystemError.boom
                }
            }
        }

        static func output(state: State, event: Event) -> String {
            ""
        }
    }

    @Test func observableSendThrowsRuntimeUnavailableWhenCancelled() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let observable = EffectObservable<T>(initialState: .init(), env: ())
        observable.cancel()

        do {
            try await observable.send(.ping)
            Issue.record("Expected RuntimeUnavailable.actorCancelled")
        } catch let error as RuntimeError {
            #expect(error == .actorCancelled)
            #expect(error.errorDescription == "The runtime is unavailable because it has already been cancelled.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func observableRequestThrowsRuntimeUnavailableWhenCancelled() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let observable = EffectObservable<T>(initialState: .init(), env: ())
        observable.cancel()

        do {
            _ = try await observable.request(.ping)
            Issue.record("Expected RuntimeUnavailable.actorCancelled")
        } catch let error as RuntimeError {
            #expect(error == .actorCancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func inputSendThrowsRuntimeUnavailableWhenOwnerIsDeallocated() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        var observable: EffectObservable<T>? = EffectObservable<T>(initialState: .init(), env: ())
        let input = try #require(observable?.input)
        observable = nil

        do {
            try await input.send(.ping)
            Issue.record("Expected RuntimeUnavailable.actorDeallocated")
        } catch let error as RuntimeError {
            #expect(error == .actorDeallocated)
            #expect(error.errorDescription == "The runtime is unavailable because it has already been deallocated.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func inputRequestThrowsRuntimeUnavailableWhenOwnerIsDeallocated() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        var observable: EffectObservable<T>? = EffectObservable<T>(initialState: .init(), env: ())
        let input = try #require(observable?.input)
        observable = nil

        do {
            _ = try await input.request(.ping)
            Issue.record("Expected RuntimeUnavailable.actorDeallocated")
        } catch let error as RuntimeError {
            #expect(error == .actorDeallocated)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func inputPostThrowsRuntimeUnavailableWhenOwnerIsDeallocated() throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        var observable: EffectObservable<T>? = EffectObservable<T>(initialState: .init(), env: ())
        let input = try #require(observable?.input)
        observable = nil

        do {
            try input.post(.ping)
            Issue.record("Expected RuntimeUnavailable.actorDeallocated")
        } catch let error as RuntimeError {
            #expect(error == .actorDeallocated)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func inputPostThrowsRuntimeUnavailableWhenRuntimeIsCancelled() throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let observable = EffectObservable<T>(initialState: .init(), env: ())
        let input = observable.input
        observable.cancel()

        do {
            try input.post(.ping)
            Issue.record("Expected RuntimeUnavailable.actorCancelled")
        } catch let error as RuntimeError {
            #expect(error == .actorCancelled)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func acceptedRequestIsCancelledWhenRuntimeIsCancelled() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let started = Expectation()
        let cancelled = Expectation()
        let timeout: UInt64 = 5_000_000_000
        let observable = EffectObservable<RequestCancellationTransducer>(
            initialState: .init(),
            env: .init(started: started, cancelled: cancelled)
        )

        let waiter = Task {
            try await observable.request(.start)
        }

        try await started.await(nanoseconds: timeout)

        observable.cancel()

        do {
            _ = try await waiter.value
            Issue.record("Expected accepted request to receive RuntimeUnavailable.actorCancelled")
        } catch let error as RuntimeError {
            #expect(error == .actorCancelled)
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        try await cancelled.await(nanoseconds: timeout)
    }

    @Test func requestThrowsLatchedSystemErrorInsteadOfHanging() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let observable = EffectObservable<LatchedFailureTransducer>(initialState: .init(), env: ())

        do {
            _ = try await observable.request(.start)
            Issue.record("Expected accepted request to receive the task failure")
        } catch let error as LatchedSystemError {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected first request error: \(error)")
        }

        do {
            _ = try await observable.request(.start)
            Issue.record("Expected later request to throw the latched system error")
        } catch let error as RuntimeError {
            #expect(error == .systemError)
        } catch {
            Issue.record("Unexpected later request error: \(error)")
        }
    }

    @Test func observableSendThrowsRuntimeUnavailableWhenRuntimeHasFailed() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let observable = EffectObservable<LatchedFailureTransducer>(initialState: .init(), env: ())

        do {
            _ = try await observable.request(.start)
            Issue.record("Expected accepted request to receive the task failure")
        } catch let error as LatchedSystemError {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected first request error: \(error)")
        }

        do {
            try await observable.send(.start)
            Issue.record("Expected later send to throw RuntimeUnavailable.runtimeFailed")
        } catch let error as RuntimeError {
            #expect(error == .systemError)
            #expect(error.errorDescription == "The runtime is unavailable because it has forcibly terminated because of a critical error.")
        } catch {
            Issue.record("Unexpected later send error: \(error)")
        }
    }
}

#endif
