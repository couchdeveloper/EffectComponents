import SwiftUI

/// A SwiftUI view that manages structured side effects using an Elm-style update loop.
///
/// `EffectView` owns an `EffectManager` for the duration of the view's lifetime.
/// State is owned by the caller (via `Binding`) so ancestor views can observe changes.
/// The `update` function is the single mutation point: it receives an event, mutates
/// state, and optionally returns an `Effect` to run or cancel.
///
/// ## Basic usage (no dependencies)
///
/// ```swift
/// enum Event { case increment, reset }
/// struct MyState { var count = 0 }
///
/// @State private var state = MyState()
///
/// EffectView(state: $state, update: { state, event -> Effect<Event, Void>? in
///     switch event {
///     case .increment: state.count += 1; return nil
///     case .reset:     state.count  = 0; return nil
///     }
/// }) { state, send in
///     Button("\(state.count)") { send(.increment) }
/// }
/// ```
///
/// ## Using `Env` for dependencies
///
/// Pass dependencies (clocks, network clients, etc.) via `Env`. The value is
/// captured once when the view appears and forwarded to every effect operation.
///
/// ```swift
/// struct Env { let clock: any Clock<Duration> }
///
/// EffectView(
///     state: $state,
///     initialEnv: Env(clock: ContinuousClock()),
///     update: { state, event in
///     switch event {
///     case .start:
///         return .run(name: "ticker") { input, env in
///             do {
///                 while true {
///                     try await env.clock.sleep(for: .seconds(1))
///                     input(.tick)
///                 }
///             } catch {
///                 // cancellation or clock error — signal via event if needed
///             }
///         }
///     case .tick:  state.count += 1; return nil
///     case .stop:  return .cancel("ticker")
///     }
/// }) { state, send in
///     Button("Start") { send(.start) }
/// }
/// ```
///
/// ## Env changes
///
/// If `Env` changes during the view's lifetime, running effects keep using the
/// original captured value. This is intentional because swapping dependencies
/// mid-flight can cause subtle bugs (for example, a task started with mock services
/// finishing after a switch to production services). To restart the view with new
/// dependencies, apply `.id(env)` at the call site (requires `Env: Hashable`). This
/// destroys the old view — cancelling all tasks — and creates a fresh instance with
/// the updated `Env`.
///
/// ## Synchronous action chains
///
/// The `.action` effect is a synchronous step that may return the next event. Each
/// returned event is processed immediately in the same run loop before any external
/// events are handled. This provides a deterministic sequence for setup work
/// (e.g. create an instance, store it in state, then continue processing). The chain
/// continues only while effects return `.action`; returning `.task` or `.cancel` ends
/// the synchronous chain.
///
@MainActor
public struct EffectView<
    State,
    Event,
    Env: Sendable,
    Content: View
>: View {
    
    @SwiftUI.State private var input: Input<Event>? = nil

    private var state: Binding<State>
    private var initialEvent: Event?
    private let env: Env
    private var update: (inout State, Event) -> Effect<Event, Env>?
    private let content: (State, Input<Event>) -> Content
    
        
    /// Creates an `EffectView` and captures `initialEnv` and `update` for the lifetime of this view identity.
    ///
    /// `initialEvent`, `initialEnv`, and `update` values are captured once when the view appears the first time.
    /// Later changes to `initialEnv` or `update` are intentionally ignored to avoid mid-flight dependency
    /// changes during running effects. To restart with new dependencies, recreate the view identity with
    /// `.id(...)`.
    ///
    /// - Parameters:
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional initial event to send when the view appears for the first time.
    ///   - initialEnv: An environment value to capture for the lifetime of this view identity.
    ///   - update: A function that updates the state and returns an optional effect.
    ///   - content: A view builder that creates the content of the view.
    ///
    /// ## Example:
    /// ```swift
    /// EffectView(
    ///     state: $state,
    ///     initialEnv: env,
    ///     update: Self.update
    /// ) { state, send in
    ///     Button("Start") { send(.start) }
    /// }
    /// .id(env.id)
    /// ```
    public init(
        state: Binding<State>,
        initialEvent: Event? = nil,
        initialEnv: Env,
        update: @escaping (inout State, Event) -> Effect<Event, Env>?,
        @ViewBuilder content: @escaping (State, Input<Event>) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = initialEnv
        self.update = update
        self.content = content
    }
    
    public var body: some View {
        HStack {
            if let input {
                content(self.state.wrappedValue, input)
            } else {
                // transparent placeholder; holds layout until effectManager is ready
                Color.clear 
                    .frame(maxWidth: 1, maxHeight: 1)
            }
        }
        .task {
            guard self.input == nil else {
                return
            }

            let effectManager = EffectManager()
            let stateBinding = self.state
            let env = self.env
            let update = self.update
            let send = { @MainActor @Sendable (event: Event, input: Input<Event>, continuation: CheckedContinuation<Void, Never>?) in
                Self.compute(
                    event: event,
                    continuation: continuation,
                    state: stateBinding,
                    effectManager: effectManager,
                    input: input,
                    env: env,
                    update: update
                )
            }
            self.input = Input(send: send)
            if let event = initialEvent {
                input?.send(event)
            }
        }
    }
    
    private static func compute(
        event: Event,
        continuation: CheckedContinuation<Void, Never>?,
        state: Binding<State>,
        effectManager: EffectManager,
        input: Input<Event>,
        env: Env,
        update: (inout State, Event) -> Effect<Event, Env>?
    ) {
        var nextEvent: Event? = event
        var cont = continuation
        while let event = nextEvent {
            nextEvent = nil
            if let effect = update(&state.wrappedValue, event) {
                (nextEvent, cont) = executeEffect(
                    effect,
                    continuation: cont,
                    effectManager: effectManager,
                    input: input,
                    env: env
                )
            } else {
                cont?.resume()
                cont = nil
            }
        }
        assert(cont == nil)
    }
    
    private static func executeEffect(
        _ effect: Effect<Event, Env>,
        continuation: CheckedContinuation<Void, Never>?,
        effectManager: EffectManager,
        input: Input<Event>,
        env: Env
    ) -> (Event?, CheckedContinuation<Void, Never>?) {
        switch effect {
        case .task(name: let name, priority: let priority, operation: let operation):
            effectManager.add(
                name: name,
                priority: priority,
                operation: {
                    await operation(input, env)
                    continuation?.resume()
                }
            )
            return (nil, nil)

        case .event(let event):
            return (event, continuation)
            
        case .action(action: let action):
            let event = action(env)
            if event == nil {
                continuation?.resume()
                return (nil, nil)
            }
            return (event, continuation)

        case .cancel(let name):
            effectManager.cancel(name: name)
            continuation?.resume()
            return (nil, nil)

        case .sequence(let effects):
            guard let last = effects.last else {
                continuation?.resume()
                return (nil, nil)
            }
            for effect in effects.dropLast() {
                _ = executeEffect(effect, continuation: nil, effectManager: effectManager, input: input, env: env)
            }
            return executeEffect(last, continuation: continuation, effectManager: effectManager, input: input, env: env)
        }
    }
}

extension EffectView where Env == Void {
    
    /// Creates an `EffectView` and captures `update` for the lifetime of this view identity.
    /// 
    /// The `update` value is captured once when the view appears the first time.
    /// Later changes to `update` are intentionally ignored.
    /// 
    /// `initialEvent`, and `update` values are captured once when the view appears the first time.
    /// Later changes to `initialEnv` or `update` are intentionally ignored to avoid mid-flight dependency
    /// changes during running effects. To restart with new dependencies, recreate the view identity with
    /// `.id(...)`.
    ///
    /// - Parameters:
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional initial event to send when the view appears for the first time.
    ///   - update: A function that updates the state and returns an optional effect.
    ///   - content: A view builder that creates the content of the view.
    /// 
    /// ## Example:
    /// ```swift
    /// EffectView(
    ///     state: $state,
    ///     initialEnv: env,
    ///     update: Self.update
    /// ) { state, send in
    ///     Button("Start") { send(.start) }
    /// }
    /// .id(env.id)
    /// ```
    public init(
        state: Binding<State>,
        initialEvent: Event? = nil,
        update: @escaping (inout State, Event) -> Effect<Event, Void>?,
        @ViewBuilder content: @escaping (State, Input<Event>) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = ()
        self.update = update
        self.content = content
    }
}

// MARK: - Implementation

@MainActor
fileprivate final class EffectManager {
    private var tasks: Set<TaskID> = []
    
    init() {
        print("EffectManager: init")
    }
    
    isolated deinit {
        print("EffectManager: deinit")
        tasks.forEach { $0.task.cancel() }
    }

    @discardableResult
    func cancel(name: String) -> Bool {
        if let taskId = tasks.first(where: { $0.name == name }) {
            taskId.task.cancel()
            return true
        } else {
            return false
        }
    }

    func add(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Void
    ) {
        if let taskName = name {
            cancel(name: taskName)
        }
        let id = Self.makeTaskID(name: name, priority: priority, operation: operation)
        tasks.insert(id)
        Task { [weak self] in
            defer {
                self?.complete(id: id)
            }
            await id.task.value
        }
    }

    private struct TaskID: Hashable, Equatable {
        let name: String?
        let task: Task<Void, Never>
    }
    
    private func complete(id: TaskID) {
        guard let _ = tasks.remove(id) else {
            fatalError("could not find task with id \(id)")
        }
    }

    private static func makeTaskID(
        name: String? = nil,
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Void
    ) -> TaskID {
        TaskID(
            name: name,
            task: Task(priority: priority, operation: operation)
        )
    }
    
}
