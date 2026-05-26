import SwiftUI

/// A SwiftUI view that manages structured side effects via an Elm-style update loop.
///
/// `EffectView` owns the task scheduler for the duration of its view identity.
/// State is held by the caller via `Binding` so ancestor views can observe changes.
/// The supplied transducer type is the single mutation authority: it receives events,
/// mutates state, and optionally returns an ``Effect`` to run or cancel.
///
/// ### Basic usage
///
/// ```swift
/// typealias Counter = CounterFeature.Transducer
///
/// @State private var state = Counter.State()
///
/// EffectView(
///     of: Counter.self,
///     state: $state,
/// ) { state, input in
///     Button("\(state.count)") {
///         try? input.post(.increment)
///     }
/// }
/// ```
/// > Note: In this case it is safe to write `try?` since we can ignore the error when
///   attempting to dispatch an event when it happens within the Button action.
///
/// ### Using `Env` for dependencies
///
/// Pass dependencies (clocks, API clients, etc.) via `Env`. The value is captured
/// once when the view appears and forwarded to every effect.
///
/// ```swift
/// typealias Feature = MoviesFeature.Transducer
/// @State private var state = Feature.State()
/// struct Env { let api: any APIClient }
///
/// EffectView(
///     of: Feature.self,
///     state: $state,
///     initialEnv: Env(api: liveAPI),
/// ) { state, input in
///     Button("Load") {
///         try? input.post(.load)
///     }
/// }
/// ```
///
/// ### Env changes
///
/// If `Env` changes during the view's lifetime, running effects keep the original
/// captured value. To restart with new dependencies, apply `.id(env)` at the call
/// site (requires `Env: Hashable`). This destroys the old view — cancelling all
/// tasks — and creates a fresh instance with the updated `Env`.
///
/// ### Generic parameters
///
/// - `State`: The type of the view's mutable state.
/// - `Event`: The event type driving state transitions.
/// - `Env`: The dependency environment. Use `Void` for no dependencies.
/// - `Output`: The value returned to callers of ``Input/request(_:)``.
///   Use `Void` when no return value is needed.
/// - `Content`: The view builder output type.
@MainActor
public struct EffectView<
    T: Transducer,
    Content: View
>: View where T.Output: Sendable, T.Env: Sendable, T.Effect == TransducerEffect<T.Event, T.Env, T.Output>, T.Event: Sendable {
    
    public typealias State = T.State
    public typealias Event = T.Event
    public typealias Env = T.Env
    public typealias Output = T.Output
    public typealias Effect = T.Effect
    
    public typealias Input = EffectViewInput<Event, Output>
        
    @SwiftUI.State private var send: Send<Event, Input, Output>?

    private var state: Binding<State>
    private var initialEvent: Event?
    private let env: Env
    private let content: (State, Input) -> Content
    
        
    /// Creates an effect-managed view with a captured dependency environment.
    ///
    /// The transducer type, `initialEvent`, and `initialEnv` are captured once when
    /// the view appears for the first time. Later changes are intentionally ignored
    /// to avoid mid-flight dependency swaps during running effects. To restart with
    /// new dependencies, use `.id(env)` at the call site when that identity model
    /// makes sense for your feature.
    ///
    /// ```swift
    /// EffectView(
    ///     of: Feature.self,
    ///     state: $state,
    ///     initialEnv: env,
    /// ) { state, input in
    ///     Button("Start") {
    ///         try? input.post(.start)
    ///     }
    /// }
    /// .id(env.id)
    /// ```
    ///
    /// - Parameters:
    ///   - of: The transducer type.
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional event sent when the view first appears.
    ///   - initialEnv: The environment captured for this view's lifetime.
    ///   - content: Builds the view from current state and an ``Input`` handle.
    public init(
        of: T.Type = T.self,
        state: Binding<State>,
        initialEvent: Event? = nil,
        initialEnv: Env,
        @ViewBuilder content: @escaping (State, Input) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = initialEnv
        self.content = content
    }
    
    public var body: some View {
        HStack {
            if let send {
                content(self.state.wrappedValue, Input(send))
            } else {
                // transparent placeholder; holds layout until effectManager is ready
                Color.clear 
                    .frame(maxWidth: 1, maxHeight: 1)
            }
        }
        .task {
            guard self.send == nil else {
                return
            }
            self.send = T.makeSend(
                with: Input.self,
                storage: self.state,
                env: self.env
            )
            if let event = initialEvent {
                do {
                    try await Input(send!).send(event)
                } catch {
                    try? self.send?.control(.systemError(error))
                }
            }
        }
    }
}


extension EffectView where Env == Void {
    
    /// Creates an effect-managed view with no external dependencies.
    ///
    /// The transducer type and `initialEvent` are captured once when the view
    /// appears for the first time. To reset the runtime, recreate the view's
    /// identity with `.id(...)`.
    ///
    /// ```swift
    /// EffectView(
    ///     of: Feature.self,
    ///     state: $state,
    /// ) { state, input in
    ///     Button("Start") {
    ///         try? input.post(.start)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - of: The transducer type.
    ///   - state: A `Binding` to the view's state, owned by the caller.
    ///   - initialEvent: An optional event sent when the view first appears.
    ///   - content: Builds the view from current state and an ``Input`` handle.
    public init(
        of: T.Type = T.self,
        state: Binding<State>,
        initialEvent: Event? = nil,
        @ViewBuilder content: @escaping (State, Input) -> Content
    ) {
        self.state = state
        self.initialEvent = initialEvent
        self.env = ()
        self.content = content
    }
}

extension SwiftUI.Binding: Storage {
    public var value: Value {
        get {
            self.wrappedValue
        }
        nonmutating set {
            self.wrappedValue = newValue
        }
    }
}
