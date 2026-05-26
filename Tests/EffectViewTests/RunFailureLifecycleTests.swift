import Foundation
import Testing
import EffectView

#if false // Feature run is not yet implemented
@Suite("Run stub")
struct RunFailureLifecycleTests {

    private final class TestStorage<Value>: Storage {
        init(value: Value) {
            self.value = value
        }

        var value: Value
    }

    private struct StubInput<Event, Output>: TransducerInput, Sendable {
        func post(_ event: sending Event) throws {}

        func request(_ event: Event) async throws -> Output? {
            nil
        }
    }

    @MainActor
    @Test func mainActorRunStubThrowsNotImplemented() async throws {
        enum T: Transducer {
            struct State: Equatable, Sendable { var count = 0 }
            enum Event: Sendable { case increment }

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .increment:
                    state.count += 1
                    return nil
                }
            }
        }

        let input = StubInput<T.Event, T.Output>()
        let send = T.makeSend(
            with: StubInput<T.Event, T.Output>.self,
            storage: TestStorage(value: T.State()),
            env: ()
        )

        do {
            _ = try await T.run(send: send, initialState: T.State(), input: input)
            Issue.record("Expected RunError.notImplemented")
        } catch let error as RunError {
            #expect(error == .notImplemented)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @TestGlobalActor
    func globalActorRunStubThrowsNotImplemented() async throws {
        enum T: Transducer {
            struct State: Equatable, Sendable { var count = 0 }
            enum Event: Sendable { case increment }

            static func update(_ state: inout State, event: Event) -> Effect? {
                switch event {
                case .increment:
                    state.count += 1
                    return nil
                }
            }
        }

        let input = StubInput<T.Event, T.Output>()
        let send = T.makeSend(
            systemActor: TestGlobalActor.shared,
            with: StubInput<T.Event, T.Output>.self,
            storage: TestStorage(value: T.State()),
            env: ()
        )

        do {
            _ = try await T.run(send: send, initialState: T.State(), input: input)
            Issue.record("Expected RunError.notImplemented")
        } catch let error as RunError {
            #expect(error == .notImplemented)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
#endif
