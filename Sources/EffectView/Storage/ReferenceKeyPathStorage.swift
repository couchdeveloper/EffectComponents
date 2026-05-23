internal struct ReferenceKeyPathStorage<Host, Value>: Storage {

    init(host: Host, keyPath: ReferenceWritableKeyPath<Host, Value>) {
        self.host = host
        self.keyPath = keyPath
    }

    private let host: Host
    private let keyPath: ReferenceWritableKeyPath<Host, Value>

    var value: Value {
        get {
            host[keyPath: keyPath]
        }
        nonmutating set {
            host[keyPath: keyPath] = newValue
        }
    }
}

internal struct WeakReferenceKeyPathStorage<Host: AnyObject, Value>: Storage {

    init(host: Host, keyPath: ReferenceWritableKeyPath<Host, Value>) {
        self.host = host
        self.keyPath = keyPath
    }

    private weak var host: Host?
    private let keyPath: ReferenceWritableKeyPath<Host, Value>

    var value: Value {
        get {
            guard let host = host else {
                fatalError(
                    "Value accessed through weak ReferenceKeyPathStorage has been deallocated.")
            }
            return host[keyPath: keyPath]
        }
        nonmutating set {
            guard let host = host else {
                fatalError(
                    "Value accessed through weak ReferenceKeyPathStorage has been deallocated.")
            }
            host[keyPath: keyPath] = newValue
        }
    }
}

/// Storage adapter that reads and writes through an unowned reference key path.
///
/// Use this when the storage host is guaranteed to outlive the adapter and state
/// should be accessed through a reference type rather than copied locally.
public struct UnownedReferenceKeyPathStorage<Host: AnyObject, Value>: Storage {

    init(host: Host, keyPath: ReferenceWritableKeyPath<Host, Value>) {
        self.host = host
        self.keyPath = keyPath
    }

    private unowned let host: Host
    private let keyPath: ReferenceWritableKeyPath<Host, Value>

    /// The value stored at `keyPath` on `host`.
    public var value: Value {
        get {
            return host[keyPath: keyPath]
        }
        nonmutating set {
            host[keyPath: keyPath] = newValue
        }
    }
}
