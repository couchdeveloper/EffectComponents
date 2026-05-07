import SwiftUI

/// `EnvReader`
///
/// The `EnvReader` provides a way to conveniently read an environment value which can be
/// used as a parameter of the initialiser of a child view.
///
/// ## Usage
///
/// ```swift
/// EnvReader(\.myEnv) { env in
///     MyView(value: env.value)
/// }
/// ```
public struct EnvReader<Content: View, Env>: View {
    @Environment private var env: Env

    private let content: (Env) -> Content

    public init(
        _ keyPath: KeyPath<EnvironmentValues, Env>,
        @ViewBuilder content: @escaping (Env) -> Content
    ) {
        self._env = .init(keyPath)
        self.content = content
    }

    public var body: some View {
        content(env)
    }
}
