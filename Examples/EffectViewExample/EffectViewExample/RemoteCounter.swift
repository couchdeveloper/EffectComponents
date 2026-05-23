import SwiftUI
import Foundation
import EffectView

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
enum RemoteCounter {
    enum Views {}
    enum Transducer {}
}

// MARK: - Remote Store

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension RemoteCounter {

    /// A minimal FSM actor implemented with `@Observable`.
    /// Private state, a public read-only projection, and an event-driven mutation API.
    /// Observers must use `withObservationTracking` (or wrap it) — the store itself
    /// does not publish a stream.
    @Observable @MainActor
    final class CounterStore: Sendable {
        
        static let shared: CounterStore = .init()
        
        private init() {}

        enum Event { case increment, decrement, reset }

        private(set) var count: Int = 0

        func send(_ event: Event) {
            switch event {
            case .increment: count += 1
            case .decrement: count -= 1
            case .reset: count  = 0
            }
        }
    }
}

// MARK: - Environment
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension EnvironmentValues {
    @Entry var remoteCounterEnv: RemoteCounter.Transducer.Env = .init(store: .shared)
}

// MARK: - Transducer
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension RemoteCounter.Transducer: Transducer {
    
    struct State {
        var count: Int = 0
        var lastDelta: Int = 0
    }

    enum Event {
        case start
        case storeChanged(newCount: Int)
        case incrementTapped
        case decrementTapped
        case resetTapped
    }

    struct Env: Identifiable {
        public let id: UUID = .init()
        let store: RemoteCounter.CounterStore
    }
    
    static func update(
        _ state: inout State,
        event: Event
    ) -> Effect? {
        switch event {

        case .start:
            return observe(
                \.store, keyPath: \.count,
                 id: "observe-store-count"
            ) { input, value in
                print("observation-handler store.count: ", value)
                try? await input.request(.storeChanged(newCount: value))
            }

        case .storeChanged(let newCount):
            // The only path that writes the mirrored value.
            print("received event: \(event), state: \(state)")
            
            state.lastDelta = newCount - state.count
            state.count = newCount
            return nil

        case .incrementTapped:
            print("incrementTapped")
            return run { input, env in
                await env.store.send(.increment)
            }

        case .decrementTapped:
            print("decrementTapped")
            return run { _, env in
                await env.store.send(.decrement)
            }

        case .resetTapped:
            print("resetTapped")
            return run { _, env in
                await env.store.send(.reset)
            }
        }
    }
}

// MARK: - Views
@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension RemoteCounter.Views {
    
    typealias Transducer = RemoteCounter.Transducer
    typealias ViewState = Transducer.State
    typealias Env = Transducer.Env

    struct ContentView: View {

        var body: some View {
            EnvReader(\.remoteCounterEnv) { env in
                CounterView(env: env)
            }
        }
    }

    struct CounterView: View {

        @State private var state = ViewState()
        let env: Env


        var body: some View {
            EffectView(
                of: Transducer.self,
                state: $state,
                initialEvent: .start,
                initialEnv: env
            ) { state, send in
                VStack(spacing: 20) {
                    Text("\(state.count)")
                        .font(Font.largeTitle.monospacedDigit())
                    Text(deltaLabel(state.lastDelta))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Button("−") { send(.decrementTapped) }
                        Button("+") { send(.incrementTapped) }
                        Button("Reset") { send(.resetTapped) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .id(env.id)
        }

        private func deltaLabel(_ delta: Int) -> String {
            switch delta {
            case 0:    return "0"
            case 1...: return "+\(delta)"
            default:   return "\(delta)"
            }
        }
    }
}

// MARK: - Previews
#Preview {
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) {
        RemoteCounter.Views.ContentView()
    } else {
        Text("RemoteCounter not available on this OS version")
    }
}
