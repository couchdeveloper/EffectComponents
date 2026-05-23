import Foundation

// TODO: we can simplify this. Rename to "CancellationError". CancellationError may have an underlying error specifying the detailed reason.
/// Boundary error indicating that the runtime can no longer accept or complete work.
public enum RuntimeUnavailable: LocalizedError, Equatable, Sendable {
    /// The host cancelled the runtime before this call could proceed.
    case actorCancelled

    /// The host object was deallocated before this call could enter the runtime.
    case actorDeallocated

    /// The runtime latched a critical system failure and stopped accepting work.
    case systemError

    /// The current path was cancelled before completion.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .actorCancelled:
            return "The runtime is unavailable because it has already been cancelled."
        case .actorDeallocated:
            return "The runtime is unavailable because it has already been deallocated."
        case .systemError:
            return "The runtime is unavailable because it has forcibly terminated because of a critical error."
        case .cancelled:
            return "The runtime is unavailable because it has been cancelled."

        }
    }
}

func runtimeBoundaryError(for error: any Swift.Error) -> any Swift.Error {
    if error is CancellationError {
        return error
    }
    if let runtimeUnavailable = error as? RuntimeUnavailable {
        return runtimeUnavailable
    }
    return RuntimeUnavailable.systemError
}

enum RuntimeError: Swift.Error {
    
    // could not perform send, because Send is deallocated
    case sendUnavailable
    
    case noInput
}
