/// A protocol that abstracts different storage implementations for transducer state.
///
/// `EffectView` uses `Storage` internally to read and write state through a common
/// interface, whether the backing state lives in local storage, a reference host,
/// or a SwiftUI `Binding`.
///
/// Most library users will work with higher-level runtime types rather than with
/// `Storage` directly.
public protocol Storage<Value> {
    associatedtype Value

    /// The current stored value.
    var value: Value { get nonmutating set }
}

internal struct LocalStorage<Value>: Storage {
    final class Reference {
        var value: Value

        init(value: Value) {
            self.value = value
        }
    }

    init(value: Value) {
        storage = Reference(value: value)
    }

    private let storage: Reference

    var value: Value {
        get {
            storage.value
        }
        nonmutating set {
            storage.value = newValue
        }
    }
}
