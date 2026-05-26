#if canImport(SwiftUI) && (canImport(UIKit) || canImport(AppKit))
import Foundation
import Testing
import SwiftUI
@testable import EffectComponents
#if canImport(Observation)
import Observation
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
struct TestView<State, Content: View>: View {
    
    @SwiftUI.State private var storage: State
    private let content: (Binding<State>) -> Content
    
    init(initialState: State, @ViewBuilder content: @escaping (Binding<State>) -> Content) {
        self._storage = .init(wrappedValue: initialState)
        self.content = content
    }
    
    var body: some View {
        content($storage)
    }
}

#if canImport(UIKit)
    typealias HostingController = UIHostingController<AnyView>
    typealias PlatformWindow = UIWindow
#elseif canImport(AppKit)
    typealias HostingController = NSHostingController<AnyView>
    typealias PlatformWindow = NSWindow
#endif
    
struct EmbedInWindowAndMakeKeyTimeoutError: Error {}


@MainActor
func embedInWindowAndMakeKey<V: View>(_ view: V, timeout: TimeInterval = 1.0) async throws -> (HostingController, PlatformWindow) {
    var hostingController: HostingController?
    var window: PlatformWindow?
    var isResumed = false
    
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let timeoutCancelTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 100_000_000 + 0.5))
            guard isResumed == false else { return }
            isResumed = true
            continuation.resume(throwing: EmbedInWindowAndMakeKeyTimeoutError())
        }

        hostingController = HostingController(
            rootView: AnyView(
                view.onAppear {
                    DispatchQueue.main.async {
                        guard isResumed == false else { return }
                        timeoutCancelTask.cancel()
                        isResumed = true
                        continuation.resume()
                    }
                }
            )
        )
        
#if canImport(UIKit)
        window = UIWindow()
        window!.rootViewController = hostingController
        window!.makeKeyAndVisible()
#elseif canImport(AppKit)
        window = NSWindow(contentViewController: hostingController!)
        window!.makeKeyAndOrderFront(nil)
#endif
    }
    
    return (hostingController!, window!)
}

@MainActor
func cleanup(_ window: PlatformWindow?) {
#if canImport(UIKit)
    window?.isHidden = true
#elseif canImport(AppKit)
    window?.close()
    window?.orderOut(nil)
#endif
}

@MainActor
func testView<State, Content: View>(
    initialState: State,
    @ViewBuilder content: @escaping @MainActor (Binding<State>) -> Content,
    expect: @escaping @MainActor () async throws -> ()
) async throws {
    CATransaction.begin()
    
    let testView = TestView(initialState: initialState) { binding in
        content(binding)
    }
    let (_, window) = try await embedInWindowAndMakeKey(testView)

    do {
        try await expect()
        await teardown()
    } catch {
        await teardown()
        throw error
    }
    
    func teardown() async {
        window.close()
        CATransaction.commit()
        CATransaction.flush()
            
        // Drain the AppKit Window Server queue completely before exiting the test frame
        // This stops the next loop iteration from colliding with trailing CA commits.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for _ in 0..<10 {
                let date = Date(timeIntervalSinceNow: 0.005)
                RunLoop.current.run(until: date)
            }
            continuation.resume()
        }
        
        // Final yield to clear async MainActor scheduling overhead
        await Task.yield()
    }
}

#endif
