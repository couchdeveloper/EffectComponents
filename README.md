# EffectView

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcouchdeveloper%2FEffectView%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/couchdeveloper/EffectView)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcouchdeveloper%2FEffectView%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/couchdeveloper/EffectView)

EffectView is a SwiftUI library for event-driven state management.

Here, an *effect* means follow-up work caused by a state transition: starting a task, calling a service, waiting, cancelling, observing, or sending the next event back into the system.

You can think of it as SwiftUI's `task` modifier taken further. Instead of attaching async work ad hoc to views, you return effects from `update`, and the runtime tracks, replaces, cancels, and routes that work by event.

EffectView is for SwiftUI developers who are tired of ViewModels that keep absorbing async methods, loading flags, `Task` handles, cancellation logic, and UI glue. It gives your view one event-driven place where state changes are decided.

## The problem

Most ViewModels start small and quickly turn into this:

- button actions and `task` modifiers mutate state
- view-scoped tasks are cancelled when the view disappears, while deliberate cancellation stays awkward
- ViewModel logic starts fighting race conditions
- logic gets split across view, ViewModel, and model
- two-way bindings further complicate the code and edge cases get missed
- tests get harder to write, and mocks replace logic instead of verifying it

The SwiftUI `task` modifier behavior is often surprising in practice. A timer started from a tab's root view is cancelled when the user switches tabs, then restarted when the view appears again. Work you expected to keep running gets torn down and started again just because the view went off-screen.

## The solution

With EffectView, you move a feature's logic into a small stand-alone enum that declares `State`, `Event`, and one `update` function.

`update` is a plain synchronous function: it receives the current state and an event, changes state, and decides what should happen next. It does not call services, start tasks, or cause side effects itself.

If more work is needed, `update` returns an effect: just a function, possibly async, that the runtime executes one step later and where those side effects happen. That split keeps the logic easy to read and easy to test.

If you know Redux or TCA, a `Transducer` plays a similar role to what those architectures often call a reducer. EffectView uses "transducer" because `update` does more than reduce state from an event: it also emits the next effect for the runtime to execute.

The example below is a small debounced search feature. Read it as a transition table: query changes put the feature into a loading state and start a named search task; response events then settle the state back into either results or an error.

```swift
import EffectView
import SwiftUI

enum SearchFeature: Transducer {
    struct State {
        var query = ""
        var isLoading = false
        var results: [String] = []
        var errorMessage: String?
    }

    enum Event {
        case queryChanged(String)
        case searchResponse([String])
        case searchFailed(String)
    }

    struct Env: Sendable {
        var search: @Sendable (String) async throws -> [String]
    }

    static func update(_ state: inout State, event: Event) -> Effect? {
        switch event {
        case .queryChanged(let query):
            state.query = query
            state.isLoading = true
            state.errorMessage = nil

            return run(id: "search") { input, env in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                do {
                    let results = try await env.search(query)
                    try input.post(.searchResponse(results))
                } catch {
                    try input.post(.searchFailed(error.localizedDescription))
                }
            }

        case .searchResponse(let results):
            state.results = results
            state.isLoading = false
            return nil

        case .searchFailed(let message):
            state.results = []
            state.errorMessage = message
            state.isLoading = false
            return nil
        }
    }
}
```

`update` is the only place that decides how the feature changes.

When `update` returns `nil`, processing stops there. When `update` returns `.run(id: "search")`, the runtime starts that async job, tracks it by identifier, and routes follow-up events back through `update`. That task can also be cancelled in the update function by its identifier.

That means no `Task?` stored in a ViewModel, no ad-hoc mutation from random callbacks, and no guessing where the last state change came from.

## Use it from SwiftUI

```swift
struct SearchView: View {
    @State private var state = SearchFeature.State()

    let env: SearchFeature.Env

    var body: some View {
        EffectView(
            of: SearchFeature.self,
            state: $state,
            initialEnv: env
        ) { state, input in
            VStack {
                TextField(
                    "Search",
                    text: Binding(
                        get: { state.query },
                        set: { try? input.post(.queryChanged($0)) }
                    )
                )

                if state.isLoading {
                    ProgressView()
                }

                List(state.results, id: \.self, rowContent: Text.init)
            }
            .padding()
        }
    }
}
```

The view renders state and posts events. The feature logic stays in `update`.

## Why this is useful

- state changes stay local and explicit
- async work is started from one place
- repeated work can be replaced by identifier
- tests can drive `update` with plain values

## Installation

```swift
.package(url: "https://github.com/couchdeveloper/EffectView.git", from: "0.1.0")
```

Add `EffectView` to your target dependencies.

## Learn more

- [Recipes](Documentation/Recipes.md)
- [SwiftUI first](Documentation/SwiftUIFirst.md)
- [Taming async tasks in SwiftUI views](Documentation/TamingAsyncTasksInSwiftUIViews.md)
- [Bridging event-driven and imperative code](Documentation/BridgingEventDrivenAndImperative.md)

## License

Apache License, Version 2.0
