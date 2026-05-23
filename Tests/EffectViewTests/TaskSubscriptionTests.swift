#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
import Foundation
import Testing
import SwiftUI
import EffectView

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


@Suite("Task subscription")
@MainActor
struct TaskSubscriptionTests {
    
    final actor InvocationCounter: Sendable {
        private(set) var count = 0
        
        init() {}
        
        @discardableResult
        func increment() -> Int {
            count += 1
            return count
        }
    }
}

@MainActor
extension TaskSubscriptionTests {
    
    @Test func subscribeSharesNamedTaskResultBetweenWaiters() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let started: Expectation
            let release: Expectation
            let timeout: UInt64
        }

        final class RequestProbe: @unchecked Sendable {
            let secondLoad: Expectation

            init(secondLoad: Expectation) {
                self.secondLoad = secondLoad
            }
        }

        enum T: Transducer {
            struct State: Equatable {
                var loadCount = 0
                let probe: RequestProbe

                static func == (lhs: Self, rhs: Self) -> Bool {
                    lhs.loadCount == rhs.loadCount
                }
            }
            enum Event: Sendable { case load }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    state.loadCount += 1
                    if state.loadCount == 2 {
                        state.probe.secondLoad.fulfill()
                    }
                    return request(id: "shared-load", option: .subscribe) { _, env in
                        await env.counter.increment()
                        env.started.fulfill()
                        do {
                            try await env.release.await(nanoseconds: env.timeout)
                        } catch {
                            Issue.record(error, "Test Invariant failure: timeout. Increase the timeout value and run tests again.")
                        }
                        return "shared-output"
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let startedExpectation = Expectation()
        let secondLoadExpectation = Expectation()
        let releaseExpectation = Expectation()
        let timeout: UInt64 = 10_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let probe = RequestProbe(secondLoad: secondLoadExpectation)

        

        try await testView(initialState: T.State(probe: probe)) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    started: startedExpectation,
                    release: releaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear {
                    capturedInput = input
                }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            let firstWaiter = Task.detached { try await input.request(.load) }
            try await startedExpectation.await(nanoseconds: timeout)
            
            let secondWaiter = Task.detached { try await input.request(.load) }
            try await secondLoadExpectation.await(nanoseconds: timeout)
            releaseExpectation.fulfill()
            
            let firstOutput = try await firstWaiter.value
            let secondOutput = try await secondWaiter.value
            let count = await counter.count
            
            #expect(firstOutput == "shared-output")
            #expect(secondOutput == "shared-output")
            #expect(count == 1, "subscribe should share one underlying named task")
        }
    }

    @Test func subscribeSharedFailureLatchesSystemErrorAndCancelsWaiters() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let started: Expectation
            let release: Expectation
            let timeout: UInt64
        }

        enum SharedFailure: Error {
            case boom
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return task(id: "shared-load", option: .subscribe) { _, env in
                        await env.counter.increment()
                        env.started.fulfill()
                        try? await env.release.await(nanoseconds: env.timeout)
                        throw SharedFailure.boom
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let startedExpectation = Expectation()
        let releaseExpectation = Expectation()
        let timeout: UInt64 = 50_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    started: startedExpectation,
                    release: releaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let firstWaiter = Task { try await input.request(.load) }
            try await startedExpectation.await(nanoseconds: timeout)

            let secondWaiter = Task { try await input.request(.load) }
            await Task.yield()
            await Task.yield()
            releaseExpectation.fulfill()

            do {
                _ = try await firstWaiter.value
                Issue.record("Expected first waiter to throw the shared task failure")
            } catch let error as SharedFailure {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected first waiter error: \(error)")
            }

            do {
                _ = try await secondWaiter.value
                Issue.record("Expected second waiter to throw the shared task failure")
            } catch let error as SharedFailure {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected second waiter error: \(error)")
            }

            let count = await counter.count
            #expect(count == 1, "subscribe should share one underlying named task")        }
    }

    @Test func subscribeStartsFreshNamedTaskAfterPreviousOneCompletes() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return request(id: "shared-load", option: .subscribe) { _, env in
                        let count = await env.counter.increment()
                        return "output-\(count)"
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(counter: counter)
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let firstOutput = try await input.request(.load)
            let secondOutput = try await input.request(.load)

            #expect(firstOutput == "output-1")
            #expect(secondOutput == "output-2")
            #expect(await counter.count == 2, "a later subscriber should start a fresh named task after completion")
        }
    }

    @Test func subscribeAttachesToCancelledTrackedTaskAndReceivesItsLateResult() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let started: Expectation
            let cancelled: Expectation
            let release: Expectation
            let timeout: UInt64
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load, stop }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return request(id: "shared-load", option: .subscribe) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation > 1 {
                            return "fresh-output-\(invocation)"
                        }
                        env.started.fulfill()
                        do {
                            try await Task.sleep(nanoseconds: env.timeout)
                            return "stale-output"
                        } catch is CancellationError {
                            env.cancelled.fulfill()
                            do {
                                try await env.release.await(nanoseconds: env.timeout)
                            } catch {
                                Issue.record(error, "Test invariant failure: timeout while waiting to release cancelled task")
                            }
                            return "late-output"
                        } catch {
                            return error.localizedDescription
                        }
                    }
                case .stop:
                    return cancel("shared-load")
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let startedExpectation = Expectation()
        let cancelledExpectation = Expectation()
        let releaseExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    started: startedExpectation,
                    cancelled: cancelledExpectation,
                    release: releaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let firstWaiter = Task { try await input.request(.load) }
            try await startedExpectation.await(nanoseconds: timeout)

            try await input.send(.stop)
            try await cancelledExpectation.await(nanoseconds: timeout)

            do {
                _ = try await firstWaiter.value
                Issue.record("Expected first waiter to throw CancellationError")
            } catch is CancellationError {
                /* expected */
            } catch {
                Issue.record("Unexpected first waiter error: \(error)")
            }

            let secondWaiter = Task { try await input.request(.load) }
            await Task.yield()
            releaseExpectation.fulfill()

            let secondOutput = try await secondWaiter.value
            // TODO: Intermitently fails during test loop
            #expect(secondOutput == "late-output")
            #expect(await counter.count == 1, "subscribe should attach to the cancelled tracked task instead of starting fresh work")
        }

    }

    @Test func subscribeAttachesToCancelledTrackedTaskAndCancelsWaitersOnLateFailure() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let started: Expectation
            let cancelled: Expectation
            let release: Expectation
            let timeout: UInt64
        }

        enum LateFailure: Error {
            case boom
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load, stop }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return task(id: "shared-load", option: .subscribe) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation > 1 {
                            return "fresh-output-\(invocation)"
                        }
                        env.started.fulfill()
                        do {
                            try await Task.sleep(nanoseconds: env.timeout)
                            return "stale-output"
                        } catch is CancellationError {
                            env.cancelled.fulfill()
                            try? await env.release.await(nanoseconds: env.timeout)
                            throw LateFailure.boom
                        }
                    }
                case .stop:
                    return cancel("shared-load")
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let startedExpectation = Expectation()
        let cancelledExpectation = Expectation()
        let releaseExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    started: startedExpectation,
                    cancelled: cancelledExpectation,
                    release: releaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            let firstWaiter = Task { try await input.request(.load) }
            try await startedExpectation.await(nanoseconds: timeout)
            
            try await input.send(.stop)
            try await cancelledExpectation.await(nanoseconds: timeout)
            
            do {
                _ = try await firstWaiter.value
                Issue.record("Expected first waiter to throw CancellationError")
            } catch is CancellationError {
                /* expected */
            } catch {
                Issue.record("Unexpected first waiter error: \(error)")
            }
            
            let secondWaiter = Task { try await input.request(.load) }
            await Task.yield()
            releaseExpectation.fulfill()
            
            do {
                _ = try await secondWaiter.value
                Issue.record("Expected second waiter to throw the late task failure")
            } catch let error as LateFailure {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected second waiter error: \(error)")
            }
            
            #expect(await counter.count == 1, "subscribe should attach to the cancelled tracked task instead of starting fresh work")
        }
    }

    @Test func switchToLatestRestartsTaskAndReturnsReplacementResultToAllWaiters() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let firstStarted: Expectation
            let firstCancelled: Expectation
            let secondStarted: Expectation
            let secondRelease: Expectation
            let timeout: UInt64
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case first, second }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .first:
                    return task(id: "replaceable", option: .switchToLatest) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation == 1 {
                            env.firstStarted.fulfill()
                            do {
                                try await Task.sleep(nanoseconds: env.timeout)
                                return "stale-first-output"
                            } catch is CancellationError {
                                env.firstCancelled.fulfill()
                                throw CancellationError()
                            }
                        }
                        env.secondStarted.fulfill()
                        try? await env.secondRelease.await(nanoseconds: env.timeout)
                        return "replacement-output"
                    }
                case .second:
                    return task(id: "replaceable", option: .switchToLatest) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation == 1 {
                            env.firstStarted.fulfill()
                            do {
                                try await Task.sleep(nanoseconds: env.timeout)
                                return "stale-first-output"
                            } catch is CancellationError {
                                env.firstCancelled.fulfill()
                                throw CancellationError()
                            }
                        }
                        env.secondStarted.fulfill()
                        try? await env.secondRelease.await(nanoseconds: env.timeout)
                        return "replacement-output"
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let firstStartedExpectation = Expectation()
        let firstCancelledExpectation = Expectation()
        let secondStartedExpectation = Expectation()
        let secondReleaseExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    firstStarted: firstStartedExpectation,
                    firstCancelled: firstCancelledExpectation,
                    secondStarted: secondStartedExpectation,
                    secondRelease: secondReleaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let firstWaiter = Task { try await input.request(.first) }
            try await firstStartedExpectation.await(nanoseconds: timeout)

            let secondWaiter = Task { try await input.request(.second) }
            try await firstCancelledExpectation.await(nanoseconds: timeout)
            try await secondStartedExpectation.await(nanoseconds: timeout)
            secondReleaseExpectation.fulfill()

            let firstOutput = try await firstWaiter.value
            let secondOutput = try await secondWaiter.value
            #expect(firstOutput == "replacement-output")
            #expect(secondOutput == "replacement-output")
            #expect(await counter.count == 2, "switchToLatest should restart the active task")
        }

    }

    @Test func switchToLatestReplacementFailureCancelsAllWaiters() async throws {
        struct WorkerEnv: Sendable {
            let counter: InvocationCounter
            let firstStarted: Expectation
            let firstCancelled: Expectation
            let secondStarted: Expectation
            let secondRelease: Expectation
            let timeout: UInt64
        }

        enum ReplacementFailure: Error {
            case boom
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case first, second }
            typealias Output = String
            typealias Env = WorkerEnv

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .first:
                    return task(id: "replaceable", option: .switchToLatest) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation == 1 {
                            env.firstStarted.fulfill()
                            do {
                                try await Task.sleep(nanoseconds: env.timeout)
                                return "stale-first-output"
                            } catch is CancellationError {
                                env.firstCancelled.fulfill()
                                throw CancellationError()
                            }
                        }
                        env.secondStarted.fulfill()
                        try? await env.secondRelease.await(nanoseconds: env.timeout)
                        throw ReplacementFailure.boom
                    }
                case .second:
                    return task(id: "replaceable", option: .switchToLatest) { _, env in
                        let invocation = await env.counter.increment()
                        if invocation == 1 {
                            env.firstStarted.fulfill()
                            do {
                                try await Task.sleep(nanoseconds: env.timeout)
                                return "stale-first-output"
                            } catch is CancellationError {
                                env.firstCancelled.fulfill()
                                throw CancellationError()
                            }
                        }
                        env.secondStarted.fulfill()
                        try? await env.secondRelease.await(nanoseconds: env.timeout)
                        throw ReplacementFailure.boom
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        let counter = InvocationCounter()
        let firstStartedExpectation = Expectation()
        let firstCancelledExpectation = Expectation()
        let secondStartedExpectation = Expectation()
        let secondReleaseExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(
                    counter: counter,
                    firstStarted: firstStartedExpectation,
                    firstCancelled: firstCancelledExpectation,
                    secondStarted: secondStartedExpectation,
                    secondRelease: secondReleaseExpectation,
                    timeout: timeout
                )
            ) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let firstWaiter = Task { try await input.request(.first) }
            try await firstStartedExpectation.await(nanoseconds: timeout)

            let secondWaiter = Task { try await input.request(.second) }
            try await firstCancelledExpectation.await(nanoseconds: timeout)
            try await secondStartedExpectation.await(nanoseconds: timeout)
            secondReleaseExpectation.fulfill()

            do {
                _ = try await firstWaiter.value
                Issue.record("Expected first waiter to throw the replacement task failure")
            } catch let error as ReplacementFailure {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected first waiter error: \(error)")
            }

            do {
                _ = try await secondWaiter.value
                Issue.record("Expected second waiter to throw the replacement task failure")
            } catch let error as ReplacementFailure {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected second waiter error: \(error)")
            }

            #expect(await counter.count == 2, "switchToLatest should restart the active task")
        }
    }

    @Test("anonymous request task completes as an unshared task")
    func anonymousRequestTaskCompletesAsUnsharedTask() async throws {
        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load }
            typealias Output = String

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return request(id: nil, option: .subscribe) { _, _ in
                        "anonymous-output"
                    }
                }
            }

            static func output(state: State, event: Event) -> String { "" }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            let output = try await input.request(.load)
            #expect(output == "anonymous-output")
        }
    }
}

#else
import Testing

@Suite("Task subscription (SwiftUI unavailable)")
struct TaskSubscriptionTests {
    @Test func skipped() {}
}

#endif
