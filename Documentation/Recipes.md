# Recipes

Short, practical snippets for common EffectView patterns.

## Post an event from the view

Use `post` when the view should trigger work and continue immediately.

```swift
Button("Retry") {
    try? input.post(.retryTapped)
}

.onChange(of: query) {
    try? input.post(.queryChanged($0))
}
```

Note: in this case it is safe to write `try?` since we can ignore the error when 
attempting to dispatch an event when it happens within the button actions or 
whithin the onChange closure.



`post` is fire-and-forget. It schedules the event and returns immediately.

## Pull to refresh from the child view

Use `request` when the caller should wait until the whole triggered flow is done.

```swift
struct ProductsListView: View {
    struct Query: Equatable {
        var searchText = ""
        var selectedCategory: String?
        var sortField: SortField?
    }

    let products: [Product]
    let input: ProductsView.Input

    @State private var query = Query()

    var body: some View {
        List(products) { product in
            Text(product.title)
        }
        .refreshable {
            try? await input.request(.refresh(
                searchText: query.searchText,
                category: query.selectedCategory,
                sortField: query.sortField
            ))
        }
    }
}
```

This is the right choice for `.refreshable`, because SwiftUI keeps the spinner visible while the request is still in flight.

It is also a good shape for diffing: let the child view that owns the query state perform the refresh itself, instead of receiving an ad-hoc `refresh` closure from the parent.

Passing `input` down is stable for the lifetime of the runtime, so SwiftUI can treat the child view's action handle as unchanged across parent reevaluations.

## Prefer stable `input` over ad-hoc action closures

If a child view just needs to send or request events, pass `input` directly.

```swift
ProductsListView(
    products: content.items,
    input: input
)
```

That keeps the child boundary deterministic. A freshly-created closure from the parent is just a new callable value every render. `EffectViewInput` instead represents the same runtime handle until the runtime itself is recreated.

## Debounce or restart search automatically

Give the task an identifier. Starting the same identifier again replaces the older work.

```swift
case .queryChanged(let query):
    state.query = query
    state.isLoading = true

    return run(id: "search") { input, env in
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }

        do {
            let results = try await env.search(query)
            try input.post(.resultsLoaded(results))
        } catch {
            try input.post(.searchFailed(error.localizedDescription))
        }
    }
```

That removes the need to store and cancel `Task` handles manually.

## Cancel stale work before starting new work

Use `sequence` when one step should happen before another.

```swift
case .refresh:
    state.isRefreshing = true
    return sequence([
        cancel("load"),
        run(id: "refresh") { input, env in
            do {
                let items = try await env.loadItems()
                try input.post(.loaded(items))
            } catch {
                try input.post(.loadFailed(error.localizedDescription))
            }
        }
    ])
```

This is a concise way to say: stop the old work first, then start the replacement.

## Mirror an external `@Observable` value into feature state

Use `observe` when a feature should react to changes from an external store or model.

```swift
struct Env: Sendable {
    var store: CounterStore
}

case .startObserving:
    return observe(\.store, keyPath: \.count) { input, count in
        try await input.request(.countChanged(count))
    }

case .countChanged(let count):
    state.count = count
    return nil
```

The observation task emits the initial value immediately, then sends updates as the observed value changes.

## Keep logic easy to test

Because the decision-making stays in `update`, you can test the feature by driving state and events directly.

```swift
var state = SearchFeature.State()

let effect = SearchFeature.update(&state, event: .queryChanged("milk"))

XCTAssertEqual(state.query, "milk")
XCTAssertTrue(state.isLoading)
XCTAssertNotNil(effect)
```

The test checks what changed immediately. If needed, separate tests can exercise the returned effect path.
