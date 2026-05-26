#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
import Foundation
import Testing
import SwiftUI
@testable import EffectView
#if canImport(Observation)
import Observation
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Hosted EffectView Tests
//
// Testing strategy: wrap each EffectView in NSHostingController / UIHostingController
// to provide a real SwiftUI lifecycle. Input is captured via `onAppear` in the content
// closure — the same pattern used in Oak's TransducerView tests.
// Expectations synchronize with async state changes.

@Suite("EffectView")
@MainActor
struct EffectViewTests {

    // MARK: - Lifecycle

    @Test func contentAppearsExactlyOnce() async throws {
        enum T: Transducer {
            enum Event: Sendable { case dummy }
            struct State: Equatable { var x = 0 }
            static func update(_ state: inout State, event: Event) -> Effect? {
                nil
            }
        }
        
        var appearCount = 0
        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { _, _ in
                Color.clear.onAppear { appearCount += 1 }
            }
        } expect: {
            #expect(appearCount == 1, "content onAppear should fire exactly once on first render")
        }
    }

    @Test func initialStateIsPreserved() async throws {
        enum T: Transducer {
            struct State: Equatable { var label: String }
            enum Event: Sendable { case dummy }
            static func update(_ state: inout State, event: Event) -> Effect? {
                nil
            }
        }

        var capturedLabel: String?
        try await testView(initialState: T.State(label: "custom")) { binding in
            EffectView(of: T.self, state: binding) { state, _ in
                Color.clear.onAppear { capturedLabel = state.label }
            }
        } expect: {
            #expect(capturedLabel == "custom")
        }
    }

    // MARK: - State updates

    @Test func updateIsCalledAndStatePropagates() async throws {
        enum T: Transducer {
            struct State: Equatable { var count = 0 }
            enum Event: Sendable { case increment }
            static func update(_ state: inout State, event: Event) -> Effect? {
                state.count += 1
                return nil
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        var observedValues: [Int] = []
        let expectation = Expectation()
        
        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding
            ) { state, input in
                Text("\(state.count)")
                    .onAppear {
                        capturedInput = input
                        observedValues.append(state.count)
                    }
                    .onChange(of: state.count) { newValue in
                        observedValues.append(newValue)
                        expectation.fulfill()
                    }
            }
        } expect: {
            #expect(observedValues == [0])
            #expect(capturedInput != nil)
            try await capturedInput?.send(.increment)
            try await expectation.await(nanoseconds: timeout)
            #expect(observedValues == [0, 1])
        }
    }

    @Test func stateChangeTriggersRerender() async throws {
        enum T: Transducer {
            enum State: Equatable, Sendable { case off, on }
            enum Event: Sendable { case toggle }
            static func update(_ state: inout State, event: Event) -> Effect? {
                state = (state == .off ? .on : .off); return nil
            }
        }

        class RenderCounter: @unchecked Sendable { var count = 0 }
        let counter = RenderCounter()
        let expectation = Expectation()
        var capturedInput: EffectViewInput<T.Event, T.Output>?

        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State.off) { binding in
            EffectView(
                of: T.self,
                state: binding
            ) { state, input in
                Text(state == .on ? "on" : "off")
                    .onAppear {
                        capturedInput = input
                        counter.count += 1
                    }
                    .onChange(of: state) { _ in
                        counter.count += 1
                        expectation.fulfill()
                    }
            }
        } expect: {
            let countAfterMount = counter.count
            try await capturedInput?.send(.toggle)
            try await expectation.await(nanoseconds: timeout)
            #expect(counter.count > countAfterMount, "View should re-render after state change")
        }
    }

    @Test func inputIdentityRemainsStableAcrossRerenders() async throws {
        enum T: Transducer {
            struct State: Equatable { var count = 0 }
            enum Event: Sendable { case increment }

            static func update(_ state: inout State, event: Event) -> Effect? {
                state.count += 1
                return nil
            }
        }

        var capturedInputs: [EffectViewInput<T.Event, T.Output>] = []
        let rerenderExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Text("\(state.count)")
                    .onAppear {
                        capturedInputs.append(input)
                    }
                    .onChange(of: state.count) { _, _ in
                        capturedInputs.append(input)
                        rerenderExpectation.fulfill()
                    }
            }
        } expect: {
            #expect(capturedInputs.count == 1)
            try await capturedInputs[0].send(.increment)
            try await rerenderExpectation.await(nanoseconds: timeout)
            #expect(capturedInputs.count == 2)
            #expect(capturedInputs[0] == capturedInputs[1])
            #expect(capturedInputs[0].id == capturedInputs[1].id)
        }
    }

    // MARK: - initialEvent

    @Test func initialEventFiresOnAppear() async throws {
        // The initial event fires synchronously inside EffectView's .task, in the same
        // run-loop pass as the input setup. SwiftUI batches both state mutations into a
        // single re-render, so onChange never sees a transition. We record every event
        // in State and assert on it after onAppear fires.
        enum T: Transducer {
            enum Event: Sendable, Equatable { case start }
            struct State: Equatable { var events: [Event] = [] }
            static func update(_ state: inout State, event: Event) -> Effect? {
                // Note: update with the initial event will be called before
                // onAppear will be called
                state.events.append(event)
                return nil
            }
        }

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding, initialEvent: .start) { state, _ in
                Color.clear.onAppear {
                    #expect(state.events == [.start], "initialEvent should be processed before content onAppear fires")
                }
            }
        } expect: {
        }
    }

    // MARK: - request

    @Test func requestSuspendsUntilUpdateCompletes() async throws {
        enum T: Transducer {
            struct State: Equatable { var count = 0 }
            enum Event: Sendable { case increment }
            static func update(_ state: inout State, event: Event) -> Effect? { state.count += 1; return nil }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { _, input in
                Color.clear.onAppear {
                    capturedInput = input
                }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            // Each request() suspends until the update loop has processed the event.
            // Three sequential requests must complete without deadlock or timeout.
            try await input.request(.increment)
            try await input.request(.increment)
            try await input.request(.increment)
        }
    }

    @Test func multipleEventsProcessedInOrder() async throws {
        enum T: Transducer {
            struct State { var log: [Int] = [] }
            enum Event: Sendable { case record(Int) }
            typealias Output = [Int]
            static func update(_ state: inout State, event: Event) -> Effect? {
                if case .record(let n) = event { state.log.append(n) }
                return nil
            }
            
            static func output(state: State, event: Event) -> [Int] {
                state.log
            }
        }
        
        var capturedInput: EffectViewInput<T.Event, T.Output>?
        
        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Text("\(state.log.count)")
                    .onAppear {
                        capturedInput = input
                    }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            var outputs: [[Int]] = []
            
            // request() guarantees each update completes before the next event is sent.
            for i in 1...5 {
                outputs.append(try await input.request(.record(i)) ?? [])
            }
            
            #expect(outputs == [
                [1],
                [1, 2],
                [1, 2, 3],
                [1, 2, 3, 4],
                [1, 2, 3, 4, 5],
            ])
        }
    }

    @Test func requestReturnsOutputFromTaskClosure() async throws {
        enum T: Transducer {
            struct State: Equatable { var value: String = "" }
            enum Event: Sendable { case load, loaded(String) }
            typealias Output = String
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return request(id: "load") { input, _ in
                        // Simulate async work, aka a service function. If it was
                        // successful, fire a completion event which updates
                        // state. If it fails, send a corresponding failure event.
                        // Note: If we throw within an effect closure, we feed
                        // this error back into the system which is considered
                        // a "system error". It is preferable to handle the error or
                        // to send a corresponding error event back.
                        do {
                            try await Task.sleep(for: .milliseconds(1)) // simulate remote work
                        } catch {
                            // not handled here in the test.
                            // Production code should send a service error event,
                            // for example: `let output = try await input.request(Event.serviceFailed(error))`
                            // then return `output`.
                        }
                        let result = "hello"
                        let output = try? await input.request(Event.loaded(result)) // drives state; return discarded
                        return output // this becomes the Output?
                    }
                case .loaded(let v):
                    state.value = v
                    return nil
                }
            }
            static func output(state: State, event: Event) -> String {
                state.value
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            let output = try await input.request(.load)
            #expect(output == "hello")
        }
    }

    @Test func requestThrowsLatchedSystemErrorInsteadOfHanging() async throws {
        enum TestError: Error, Equatable {
            case boom
        }

        enum T: Transducer {
            struct State: Equatable {}
            enum Event: Sendable { case load }
            typealias Output = String

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return task(id: "load") { _, _ in
                        throw TestError.boom
                    }
                }
            }

            static func output(state: State, event: Event) -> String {
                ""
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let completion = Expectation()
        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { _, input in
                Color.clear.onAppear { capturedInput = input }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }

            do {
                _ = try await input.request(.load)
                Issue.record("Expected first request to receive the task failure")
            } catch let error as TestError {
                #expect(error == .boom)
            } catch {
                Issue.record("Unexpected first request error: \(error)")
            }

            let secondRequest = Task {
                do {
                    _ = try await input.request(.load)
                    Issue.record("Expected second request to throw RuntimeUnavailable.runtimeFailed")
                } catch let error as RuntimeError {
                    #expect(error == .systemError)
                } catch {
                    Issue.record("Unexpected second request error: \(error)")
                }
                completion.fulfill()
            }

            try await completion.await(nanoseconds: timeout)
            _ = await secondRequest.result
        }
    }

    // MARK: - Effects

    @Test func taskEffectRunsAndMutatesState() async throws {
        enum T: Transducer {
            struct State: Equatable { var loaded = false }
            enum Event: Sendable { case load, didLoad }
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .load:
                    return task(id: "fetch") { input, _ in try input.post(Event.didLoad) }
                case .didLoad:
                    state.loaded = true
                    return nil
                }
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let loadedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Text(state.loaded ? "loaded" : "idle")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.loaded) { _ in loadedExpectation.fulfill() }
            }
        } expect: {
            try await capturedInput?.send(.load)
            try await loadedExpectation.await(nanoseconds: timeout)
        }
    }

    @Test func cancelEffectStopsRunningTask() async throws {
        enum T: Transducer {
            struct State: Equatable { var ticks = 0; var running = false }
            enum Event: Sendable { case start, tick, stop }
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .start:
                    state.running = true
                    return task(id: "ticker") { input, _ in
                        do {
                            // run indefinitely, or until the "ticker" task gets cancelled
                            while true {
                                try await Task.sleep(nanoseconds: 20_000_000) // 20 ms
                                try input.post(Event.tick)
                            }
                        } catch {
                            print("Error: \(error)")
                            /* task cancelled — exit cleanly */
                        }
                    }
                case .tick:
                    state.ticks += 1
                    return nil
                case .stop:
                    state.running = false
                    return cancel("ticker")
                }
            }
        }

        class TickCounter: @unchecked Sendable { var count = 0 }
        let tickCounter = TickCounter()

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let twoTicksExpectation = Expectation(minFulfillCount: 2)
        let stoppedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Text("\(state.ticks)")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.ticks) { _ in
                        tickCounter.count += 1
                        twoTicksExpectation.fulfill()
                    }
                    .onChange(of: state.running) { isRunning in
                        if !isRunning { stoppedExpectation.fulfill() }
                    }
            }
        } expect: {
            #expect(capturedInput != nil)
            
            try await capturedInput?.send(.start)
            try await twoTicksExpectation.await(nanoseconds: timeout)
            try await capturedInput?.send(.stop)
            
            try await stoppedExpectation.await(nanoseconds: timeout)
            let countAtStop = tickCounter.count
            
            // Wait 3x the tick interval - any in-flight ticks would arrive within this window.
            try await Task.sleep(nanoseconds: 60_000_000) // 60 ms
            #expect(tickCounter.count == countAtStop, "No ticks should arrive after cancel")
        }
    }

    @Test func actionEffectChainFiresSynchronously() async throws {
        enum T: Transducer {
            struct State: Equatable { var phase = 0 }
            enum Event: Sendable { case begin, step, done }
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .begin: state.phase = 1; return action { _ in Event.step }
                case .step:  state.phase = 2; return action { _ in Event.done }
                case .done:  state.phase = 3; return nil
                }
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let readyExpectation = Expectation()
        let doneExpectation = Expectation()

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Text("\(state.phase)")
                    .onAppear {
                        capturedInput = input
                        readyExpectation.fulfill()
                    }
                    .onChange(of: state.phase) { phase in
                        if phase == 3 { doneExpectation.fulfill() }
                    }
            }
        } expect: {
            try await readyExpectation.await(nanoseconds: 5_000_000_000)
            
            // request() awaits the entire synchronous chain: begin → step → done.
            try await capturedInput?.request(.begin)
            try await doneExpectation.await(nanoseconds: 5_000_000_000)
        }
    }

    @Test func sequenceEffectCancelsThenStartsTask() async throws {
        struct WorkerEnv: Sendable { let cancelExpectation: Expectation; let timeout: UInt64 }
        enum T: Transducer {
            struct State: Equatable { var ticks = 0 }
            enum Event: Sendable { case startFirst, refresh, tick }
            typealias Env = WorkerEnv
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .startFirst:
                    // Long-running task that never ticks on its own.
                    return task(id: "worker") { input, env in
                        do {
                            try await Task.sleep(nanoseconds: env.timeout)
                        } catch {
                            env.cancelExpectation.fulfill()
                        }
                    }
                case .refresh:
                    // Cancel stale worker, immediately start a fresh one that ticks.
                    return sequence([
                        cancel("worker"),
                        task(id: "worker") { input, _ in try input.post(Event.tick) },
                    ])
                case .tick:
                    state.ticks += 1
                    return nil
                }
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let tickExpectation = Expectation()
        let cancelExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: WorkerEnv(cancelExpectation: cancelExpectation, timeout: timeout)
            ) { state, input in
                Text("\(state.ticks)")
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.ticks) { _ in
                        tickExpectation.fulfill()
                    }
            }
        } expect: {
            try await capturedInput?.send(.startFirst)
            try await capturedInput?.send(.refresh) // cancels first task, starts new one that ticks
            try await cancelExpectation.await(nanoseconds: timeout)
            try await tickExpectation.await(nanoseconds: timeout)
        }
    }

    // MARK: - Identity reset

    @Test func identityResetRestoresInitialState() async throws {
        enum T: Transducer {
            struct State: Equatable { var count = 0 }
            enum Event: Sendable { case increment }
            static func update(_ state: inout State, event: Event) -> Effect? { state.count += 1; return nil }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let resetExpectation = Expectation()
        var countsOnAppear: [Int] = []

        let timeout: UInt64 = 5_000_000_000

        let (hostingController, window) = try await embedInWindowAndMakeKey(
            TestView(initialState: T.State()) { binding in
                EffectView(of: T.self, state: binding) { _, input in
                    Color.clear.onAppear {
                        capturedInput = input
                    }
                }
            }
        )

        guard let input = capturedInput else { Issue.record("Input not captured"); return }

        try await input.request(.increment)
        try await input.request(.increment)

        // Replace the root view with a fresh instance at initial state.
        hostingController.rootView = AnyView(
            TestView(initialState: T.State()) { binding in
                EffectView(of: T.self, state: binding) { state, _ in
                    Color.clear.onAppear {
                        countsOnAppear.append(state.count)
                        resetExpectation.fulfill()
                    }
                }
            }
        )

        try await resetExpectation.await(nanoseconds: timeout)
        #expect(countsOnAppear.last == 0, "Fresh EffectView should start at count 0")
        cleanup(window)
    }

    // MARK: - Env

    @Test func envIsForwardedToTaskOperation() async throws {
        struct TaskEnv: Sendable { var value: String }
        enum T: Transducer {
            struct State: Equatable { var result = "" }
            enum Event: Sendable { case fetch, loaded(String) }
            typealias Env = TaskEnv
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .fetch:
                    return task(id: "fetch") { input, env in
                        try input.post(Event.loaded(env.value))
                    }
                case .loaded(let value):
                    state.result = value
                    return nil
                }
            }
        }

        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let loadedExpectation = Expectation()

        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: TaskEnv(value: "hello from env")
            ) { state, input in
                Text(state.result)
                    .onAppear {
                        capturedInput = input
                    }
                    .onChange(of: state.result) { _ in loadedExpectation.fulfill() }
            }
        } expect: {
            try await capturedInput?.send(.fetch)
            try await loadedExpectation.await(nanoseconds: timeout)
        }
    }

    // MARK: - Observation

    #if canImport(Observation)

    // Shared observable type for observation tests. Defined at member scope because
    // @Observable (an extension macro) cannot be applied to local types.
    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Observable final class ObservableCounter: @unchecked Sendable { var value = 0 }

    // Holds a weak reference without triggering the "weak var never mutated" warning.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        weak var object: T?
        init(_ v: T) { self.object = v }
    }

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func observeDoesNotRetainObservable() async throws {
        // Effect.observe(object:keyPath:) documents that the object is held weakly.
        // Verify that dropping all external strong references deallocates the observed
        // object even while the EffectView is still live.
        enum T: Transducer {
            struct State: Equatable { var latest = -1 }
            enum Event: Sendable { case watch(ObservableCounter), tick(Int) }
            static func update(_ state: inout State, event: Event) -> TransducerEffect<Event, Void, Void>? {
                switch event {
                case .watch(let c):
                    return observe(c, keyPath: \.value) { input, v in
                        // Regarding: using observe with isolated action
                        // Note: request is *nonisolated* for this Input. Thus we
                        // cannot use `isolatedOperation` - we need to have
                        // a Sendable operation which also requires Input to be
                        // sendable!
                        try? await input.request(.tick(v))
                    }
                case .tick(let v):
                    state.latest = v
                    return nil
                }
            }
        }

        var counter: ObservableCounter? = ObservableCounter()
        let weakBox = WeakBox(counter!)
        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let firstTickExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(of: T.self, state: binding) { state, input in
                Color.clear
                    .onAppear { capturedInput = input }
                    .onChange(of: state.latest) { _ in firstTickExpectation.fulfill() }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            // Start observation. The taskIsolated closure captures the counter strongly
            // only until observeKeyPath returns (after the initial handler call); then the
            // task completes and releases it. Subsequent onChange callbacks use a WeakObject.
            try await input.send(.watch(counter!))
            try await firstTickExpectation.await(nanoseconds: timeout)
            
            // Yield to let the observe task finalise and release its captured reference.
            await Task.yield()
            await Task.yield()
            
            // Drop the only remaining strong reference. ARC should free the object.
            counter = nil
            await Task.yield()
            
            #expect(weakBox.object == nil,
                    "Effect.observe must not retain the observable beyond the initial task")
        }
    }

    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    @MainActor
    @Test func cancelObservationTaskStopsHandlerInvocations() async throws {
        // Verify that cancel("observe") prevents further handler calls.
        // After cancellation, mutating the observable must not deliver new values.
        struct ObsEnv: Sendable { let counter: ObservableCounter }
        class InvocationLog: @unchecked Sendable { var count = 0 }
        let log = InvocationLog()

        enum T: Transducer {
            struct State: Equatable { var latest = -1 }
            enum Event: Sendable { case start, stop, tick(Int) }
            typealias Env = ObsEnv
            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .start:
                    return observe(\.counter, keyPath: \.value, id: "observe") { input, value in
                        try? await input.request(.tick(value))
                        print("request(.tick(\(value))) finished")
                    }
                case .stop:
                    return cancel("observe")
                case .tick(let v):
                    state.latest = v
                    return nil
                }
            }
        }

        let counter = ObservableCounter()
        var capturedInput: EffectViewInput<T.Event, T.Output>?
        let firstTickExpectation = Expectation()
        let secondTickExpectation = Expectation()
        let timeout: UInt64 = 5_000_000_000

        try await testView(initialState: T.State()) { binding in
            EffectView(
                of: T.self,
                state: binding,
                initialEnv: ObsEnv(counter: counter)
            ) { state, input in
                Color.clear
                    .onAppear { capturedInput = input }
                    .onChange(of: state.latest) { newValue in
                        log.count += 1
                        if log.count == 1 { firstTickExpectation.fulfill() }
                        if log.count == 2 { secondTickExpectation.fulfill() }
                    }
            }
        } expect: {
            guard let input = capturedInput else { Issue.record("Input not captured"); return }
            
            // Start observing; the initial value (0) is delivered via state.
            // Caution: DO NOT use `request` for an observation task, because it will not finish before it gets cancelled.
            input.post(.start)
            try await firstTickExpectation.await(nanoseconds: timeout)
            
            // Mutate the counter; the handler should fire once more.
            counter.value = 1
            try await secondTickExpectation.await(nanoseconds: timeout)
            let countAtCancel = log.count  // expected: 2
            
            // Cancel the observation task.
            try await input.request(.stop)
            
            // Allow any last in-flight handler task a chance to drain.
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            
            // Further mutations must not trigger additional handler calls.
            counter.value = 2
            counter.value = 3
            try await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            
            #expect(log.count == countAtCancel,
                    "No handler calls expected after cancelling the observation task")
        }
    }

    #endif
}

#else
import Testing

// @Suite("EffectView (SwiftUI unavailable)")
struct EffectViewTests {
    @Test func skipped() {
        // Hosted tests require SwiftUI + AppKit or UIKit.
        // This placeholder passes so `swift test` does not report a failure on
        // platforms where SwiftUI is unavailable (e.g. Linux).
    }
}

#endif

// MARK: - Spy helper

/// Records events dispatched via `Input` so tests can assert on them.
/// `@unchecked Sendable` is intentional: all accesses happen on `@MainActor`
/// (the Input closure is `@MainActor`; assertions run on `@MainActor` too).
private final class EventSpy<Event: Sendable>: @unchecked Sendable {
    var received: [Event] = []
}

private struct TaskInput<Event: Sendable, Output: Sendable>: TransducerInput, Sendable {
    let onEvent: @Sendable @MainActor (Event) -> Void

    func post(_ event: sending Event) {
        Task { @MainActor in
            onEvent(event)
        }
    }

    func request(_ event: Event) async -> Output? {
        await MainActor.run {
            onEvent(event)
            return nil
        }
    }
}

// MARK: - Counter model (no Env)

private struct CounterState: Equatable {
    var count = 0
    var running = false
}

private enum CounterEvent: Equatable, Sendable {
    case increment, decrement, reset, start, stop, ticked
}

private func counterUpdate(
    state: inout CounterState,
    event: CounterEvent
) -> TransducerEffect<CounterEvent, Void, Void>? {
    switch event {
    case .increment:
        state.count += 1
        return nil
    case .decrement:
        state.count -= 1
        return nil
    case .reset:
        state = .init()
        return nil
    case .start:
        state.running = true
        return .init(._task(id: "ticker", priority: nil, option: .switchToLatest) { input, _ in
            try input.post(.ticked)
        })
    case .stop:
        state.running = false
        return .init(._cancel("ticker"))
    case .ticked:
        state.count += 1
        return nil
    }
}

// MARK: - Loader model (with Env)

private struct LoaderState: Equatable {
    var items: [String] = []
    var isLoading = false
    var error: String? = nil
}

private enum LoaderEvent: Equatable, Sendable {
    case load, loaded([String]), failed(String)
}

private struct LoaderEnv: Sendable {
    var fetch: @Sendable () async throws -> [String]
}

private struct LoadFetchError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func loaderUpdate(
    state: inout LoaderState,
    event: LoaderEvent
) -> TransducerEffect<LoaderEvent, LoaderEnv, Void>? {
    switch event {
    case .load:
        state.isLoading = true
        state.error = nil
        return .init(._task(id: "fetch", priority: nil, option: .switchToLatest) { input, env in
            do {
                let items = try await env.fetch()
                try input.post(.loaded(items))
            } catch {
                try input.post(.failed(error.localizedDescription))
            }
        })
    case .loaded(let items):
        state.isLoading = false
        state.items = items
        return nil
    case .failed(let message):
        state.isLoading = false
        state.error = message
        return nil
    }
}

// MARK: - Tests: pure state mutations

@Suite("State mutations")
struct StateMutationTests {

    @Test func incrementAddsOne() {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .increment)
        #expect(state.count == 1)
        #expect(effect == nil)
    }

    @Test func decrementSubtractsOne() {
        var state = CounterState(count: 3, running: false)
        let effect = counterUpdate(state: &state, event: .decrement)
        #expect(state.count == 2)
        #expect(effect == nil)
    }

    @Test func resetRestoresDefaultState() {
        var state = CounterState(count: 5, running: true)
        let effect = counterUpdate(state: &state, event: .reset)
        #expect(state == CounterState())
        #expect(effect == nil)
    }

    @Test func loadSetsIsLoadingFlag() {
        var state = LoaderState()
        _ = loaderUpdate(state: &state, event: .load)
        #expect(state.isLoading == true)
        #expect(state.error == nil)
    }

    @Test func loadedClearsLoadingAndStoresItems() {
        var state = LoaderState(items: [], isLoading: true, error: nil)
        let effect = loaderUpdate(state: &state, event: .loaded(["A", "B"]))
        #expect(state.isLoading == false)
        #expect(state.items == ["A", "B"])
        #expect(effect == nil)
    }

    @Test func failedClearsLoadingAndStoresError() {
        var state = LoaderState(items: [], isLoading: true, error: nil)
        let effect = loaderUpdate(state: &state, event: .failed("network error"))
        #expect(state.isLoading == false)
        #expect(state.error == "network error")
        #expect(effect == nil)
    }
}

// MARK: - Tests: returned Effect cases

@Suite("Effect types")
struct EffectTypeTests {

    @Test func startReturnsNamedTask() {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .start)
        #expect(state.running == true)
        guard case ._task(id: let name, _, _, _) = effect?.type, name == "ticker" else {
            Issue.record(#"Expected .task(name: "ticker")"#)
            return
        }
    }

    @Test func stopReturnsCancelForTicker() {
        var state = CounterState(count: 0, running: true)
        let effect = counterUpdate(state: &state, event: .stop)
        #expect(state.running == false)
        guard case ._cancel(let name) = effect?.type else {
            Issue.record("Expected .cancel")
            return
        }
        #expect(name == "ticker")
    }

    @Test func loadReturnsNamedFetchTask() {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case ._task(id: let name, _, _, _) = effect?.type, name == "fetch" else {
            Issue.record(#"Expected .task(name: "fetch")"#)
            return
        }
    }

    @Test func actionEffectInvokesClosureAndReturnsEvent() {
        enum Ev: Equatable, Sendable { case a, b }
        let effect = TransducerEffect<Ev, Void, Void>.init(._actionSync { _ in .b } )

        guard case ._actionSync(let run) = effect.type else {
            Issue.record("Expected .action")
            return
        }
        #expect(run(()) == .b)
    }

    @Test func actionEffectCanReturnNil() {
        enum Ev: Equatable, Sendable { case a }
        let effect = TransducerEffect<Ev, Void, Void>.init(._actionSync { _ in nil } )
        guard case ._actionSync(let run) = effect.type else {
            Issue.record("Expected .action")
            return
        }
        #expect(run(()) == nil)
    }

    @Test func sequenceContainsOrderedEffects() {
        enum Ev: Equatable, Sendable { case done }
        let effect = TransducerEffect<Ev, Void, Void>.init(._sequence([
            .init(._cancel("old")),
            .init(._task(id: "new", priority: nil, option: .switchToLatest) { _, _ in })
        ]))
        guard case ._sequence(let effects) = effect.type, effects.count == 2 else {
            Issue.record("Expected .sequence with 2 effects")
            return
        }
        guard case ._cancel("old") = effects[0].type else {
            Issue.record(#"Expected effects[0] to be .cancel("old")"#)
            return
        }
        guard case ._task(id: let name, _, _, _) = effects[1].type, name == "new" else {
            Issue.record(#"Expected effects[1] to be .task(name: "new")"#)
            return
        }
    }
}

// MARK: - Tests: async task operations

/// These tests extract the operation closure from a returned `.task` effect and
/// drive it directly — no SwiftUI hosting required.
///
/// `post` schedules work on `@MainActor` via a child Task, so one `Task.yield()`
/// after `await operation(...)` is needed to let that task run before asserting.
@Suite("Task operations")
@MainActor
struct TaskOperationTests {

    @Test func fetchSuccessSendsLoadedEvent() async {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case ._task(_, _, _, let operation) = effect?.type else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<LoaderEvent>()
        let input = TaskInput<LoaderEvent, Void> { [spy] event in spy.received.append(event) }
        try? await operation(input, LoaderEnv(fetch: { ["X", "Y"] }))
        await Task.yield()

        #expect(spy.received == [.loaded(["X", "Y"])])
    }

    @Test func fetchFailureSendsFailedEvent() async {
        var state = LoaderState()
        let effect = loaderUpdate(state: &state, event: .load)
        guard case ._task(_, _, _, let operation) = effect?.type else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<LoaderEvent>()
        let input = TaskInput<LoaderEvent, Void> { [spy] event in spy.received.append(event) }
        try? await operation(input, LoaderEnv(fetch: { throw LoadFetchError(message: "timed out") }))
        await Task.yield()

        #expect(spy.received == [.failed("timed out")])
    }

    @Test func tickerTaskEnqueuesTickedEvent() async {
        var state = CounterState()
        let effect = counterUpdate(state: &state, event: .start)
        guard case ._task(_, _, _, let operation) = effect?.type else {
            Issue.record("Expected .task"); return
        }

        let spy = EventSpy<CounterEvent>()
        let input = TaskInput<CounterEvent, Void> { [spy] event in spy.received.append(event) }
        try? await operation(input, ())
        await Task.yield()

        #expect(spy.received == [.ticked])
    }
}
