import SwiftUI
import Foundation
import EffectView

enum Counter {
    enum Views {}
    enum Transducer {}
}

// MARK: - Environment
extension EnvironmentValues {
    @Entry var counterViewEnv: Counter.Transducer.Env = .init()
}

// MARK: - Transducer
extension Counter.Transducer: EffectView::Transducer {
        
    struct State {
        var counter = 0
        init() {
            self.counter = 0
        }
    }
    
    enum Event {
        case start
        case tick
        case stop
    }
    
    struct Env: Identifiable {
        let id: UUID = .init()
        init() {}
    }
    
    static func update(
        _ state: inout State,
        event: Event
    ) -> Self.Effect? {
        switch event {
        case .start:
            state.counter = 0
            return run(id: "Counter") { input, env in
                while true {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
                        print("tick")
                        input(.tick)
                    } catch {} // most likely, the counter task has been cancelled; ignore it.
                }
            }
        case .tick:
            state.counter += 1; return nil
        case .stop:
            return cancel("Counter")
        }
    }
    
}

// MARK: - Views
extension Counter.Views {
    
    struct ContentView: View {
        var body: some View {
            EnvReader(\.counterViewEnv) {
                CounterView(env: $0)
            }
        }
    }
    
    struct CounterView: View {
        typealias Transducer = Counter.Transducer
        typealias Env = Transducer.Env
        typealias ViewState = Transducer.State
        
        @State private var state: ViewState = .init()
        let env: Env
        
        var body: some View {
            EffectView(
                of: Transducer.self,
                state: $state,
                initialEnv: env,
            ) { state, send in
                VStack {
                    Text("\(state.counter)")
                        .font(Font.largeTitle.monospacedDigit())
                    Button("Start") { send(.start) }
                    Button("Stop")  { send(.stop)  }
                }
            }
            .id(env.id) // restart the EffectView when the env changes
        }
    }
}

#Preview {
    Counter.Views.ContentView()
}
