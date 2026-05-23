import Testing
@testable import EffectView

#if canImport(Observation)

@Suite("Async action runtime")
@MainActor
struct AsyncActionRuntimeTests {

    actor AsyncGate: Sendable {
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter.resume()
            }
        }
    }

    enum AsyncActionCancellationTransducer: Transducer {
        struct State: Equatable {
            var phases: [String] = []
        }

        enum Event: Sendable {
            case start
            case finished
        }

        struct Env: Sendable {
            let started: Expectation
            let release: AsyncGate
        }

        typealias Output = String

        static func update(_ state: inout State, event: Event) -> Effect? {
            switch event {
            case .start:
                state.phases.append("start")
                return action { env in
                    env.started.fulfill()
                    await env.release.wait()
                    return .finished
                }

            case .finished:
                state.phases.append("finished")
                return nil
            }
        }

        static func output(state: State, event: Event) -> String {
            state.phases.joined(separator: ",")
        }
    }

    enum GatedAsyncActionTransducer: Transducer {
        struct State: Equatable {
            var events: [String] = []
        }

        enum Event: Sendable {
            case first
            case firstFinished
            case second
        }

        struct Env: Sendable {
            let firstStarted: Expectation
            let releaseFirst: AsyncGate
        }

        static func update(_ state: inout State, event: Event) -> Effect? {
            switch event {
            case .first:
                state.events.append("first")
                return action { env in
                    env.firstStarted.fulfill()
                    await env.releaseFirst.wait()
                    return .firstFinished
                }

            case .firstFinished:
                state.events.append("firstFinished")
                return nil

            case .second:
                state.events.append("second")
                return nil
            }
        }
    }

    @Test func requestThrowsRuntimeUnavailableWhenCancelledDuringAsyncAction() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let started = Expectation()
        let release = AsyncGate()
        let timeout: UInt64 = 5_000_000_000

        let observable = EffectObservable<AsyncActionCancellationTransducer>(
            initialState: .init(),
            env: .init(started: started, release: release)
        )

        let waiter = Task {
            try await observable.request(.start)
        }

        try await started.await(nanoseconds: timeout)
        #expect(observable.state.phases == ["start"])

        observable.cancel()
        await Task.yield()

        await release.open()

        do {
            _ = try await waiter.value
            Issue.record("Expected accepted request to receive RuntimeUnavailable.actorCancelled")
        } catch let error as RuntimeUnavailable {
            #expect(error == .actorCancelled)
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        #expect(observable.state.phases == ["start"])
    }

    @Test func concurrentSendWaitsForEarlierAsyncActionToFinish() async throws {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, visionOS 1.0, *) else {
            return
        }

        let firstStarted = Expectation()
        let releaseFirst = AsyncGate()
        let timeout: UInt64 = 5_000_000_000

        let observable = EffectObservable<GatedAsyncActionTransducer>(
            initialState: .init(),
            env: .init(firstStarted: firstStarted, releaseFirst: releaseFirst)
        )

        let firstSend = Task {
            try await observable.send(.first)
        }

        try await firstStarted.await(nanoseconds: timeout)

        let secondSend = Task {
            try await observable.send(.second)
        }

        await Task.yield()
        await Task.yield()

        #expect(observable.state.events == ["first"])

        await releaseFirst.open()

        try await firstSend.value
        try await secondSend.value

        #expect(observable.state.events == ["first", "firstFinished", "second"])
    }
}

#endif