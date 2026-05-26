import Foundation
import Testing
@testable import EffectComponents

private enum TaskManagerFailure: Error, Equatable {
    case boom
    case later
}

private enum TaskManagerStateSnapshot: Equatable, Sendable {
    case active
    case cancellingNoError
    case cancellingBoom
    case cancellingOther
    case cancelledNoError
    case cancelledBoom
    case cancelledOther
}

private actor TaskManagerHarness {
    let taskManager = TaskManager<String>()

    func request(
        identifier: TaskIdentifier,
        started: Expectation?,
        cancelled: Expectation?
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            taskManager.addTask(
                systemActor: self,
                with: identifier,
                option: .subscribe,
                continuation: continuation,
                isolatedOperation: { _ in
                    started?.fulfill()
                    do {
                        while true {
                            try await Task.sleep(nanoseconds: 50_000_000)
                        }
                    } catch is CancellationError {
                        cancelled?.fulfill()
                        throw CancellationError()
                    }
                }
            )
        }
    }

    func cancelWithError(_ error: any Error) {
        taskManager.cancel(with: error)
    }

    func cancelWithoutError() {
        taskManager.cancel()
    }

    func failTrackedTask(
        identifier: TaskIdentifier,
        started: Expectation?
    ) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            taskManager.addTask(
                systemActor: self,
                with: identifier,
                option: .subscribe,
                continuation: continuation,
                isolatedOperation: { _ in
                    started?.fulfill()
                    throw TaskManagerFailure.boom
                }
            )
        }
    }

    func checkCancellation() throws {
        try taskManager.checkCancellation()
    }

    func stateSnapshot() -> TaskManagerStateSnapshot {
        switch taskManager.state {
        case .active:
            return .active
        case .cancelling(let error):
            switch error {
            case nil:
                return .cancellingNoError
            case let error as TaskManagerFailure where error == .boom:
                return .cancellingBoom
            default:
                return .cancellingOther
            }
        case .cancelled(let error):
            switch error {
            case nil:
                return .cancelledNoError
            case let error as TaskManagerFailure where error == .boom:
                return .cancelledBoom
            default:
                return .cancelledOther
            }
        }
    }
}

@Suite("Task manager")
struct TaskManagerTests {

    @Test func cancelWithSystemErrorCancelsTrackedTasksAndRejectsNewAdds() async throws {
        let harness = TaskManagerHarness()
        let started = Expectation()
        let cancelled = Expectation()
        let timeout: UInt64 = 5_000_000_000

        let waiter = Task {
            try await harness.request(
                identifier: "tracked",
                started: started,
                cancelled: cancelled
            )
        }

        try await started.await(nanoseconds: timeout)

        await harness.cancelWithError(TaskManagerFailure.boom)

        do {
            try await harness.checkCancellation()
            Issue.record("Expected latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected latched error: \(error)")
        }

        do {
            _ = try await waiter.value
            Issue.record("Expected active waiter to receive the latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        try await cancelled.await(nanoseconds: timeout)

        do {
            _ = try await harness.request(
                identifier: "tracked",
                started: nil,
                cancelled: nil
            )
            Issue.record("Expected new waiter to be rejected after system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected rejected waiter error: \(error)")
        }
    }

    @Test func cancelWithSystemErrorKeepsFirstError() async throws {
        let harness = TaskManagerHarness()

        await harness.cancelWithError(TaskManagerFailure.boom)
        await harness.cancelWithError(TaskManagerFailure.later)

        do {
            try await harness.checkCancellation()
            Issue.record("Expected first latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func thrownTaskErrorLatchesSystemErrorAndCancelsItsWaiters() async throws {
        let harness = TaskManagerHarness()
        let started = Expectation()
        let timeout: UInt64 = 5_000_000_000

        let waiter = Task {
            try await harness.failTrackedTask(identifier: "tracked", started: started)
        }

        try await started.await(nanoseconds: timeout)

        do {
            _ = try await waiter.value
            Issue.record("Expected thrown task waiter to receive the latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        do {
            try await harness.checkCancellation()
            Issue.record("Expected latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected latched error: \(error)")
        }
    }

    @Test func cancelWithoutErrorCancelsActiveWaitersButRejectsFutureOnesAsRuntimeUnavailable() async throws {
        let harness = TaskManagerHarness()
        let started = Expectation()
        let cancelled = Expectation()
        let timeout: UInt64 = 5_000_000_000

        let waiter = Task {
            try await harness.request(
                identifier: "tracked",
                started: started,
                cancelled: cancelled
            )
        }

        try await started.await(nanoseconds: timeout)

        await harness.cancelWithoutError()

        do {
            try await harness.checkCancellation()
            Issue.record("Expected runtime unavailable cancellation")
        } catch let error as RuntimeError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected latched error: \(error)")
        }

        do {
            _ = try await waiter.value
            Issue.record("Expected active waiter to receive CancellationError")
        } catch is CancellationError {
            /* expected */
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        try await cancelled.await(nanoseconds: timeout)

        do {
            _ = try await harness.request(
                identifier: "tracked",
                started: nil,
                cancelled: nil
            )
            Issue.record("Expected future waiter to be rejected as runtime unavailable")
        } catch let error as RuntimeError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected rejected waiter error: \(error)")
        }
    }

    @Test func cancelTransitionsToCancelledStateImmediatelyWhenNoTasksAreTracked() async {
        let harness = TaskManagerHarness()

        await harness.cancelWithError(TaskManagerFailure.boom)

        #expect(await harness.stateSnapshot() == .cancelledBoom)
    }

    @Test func cancelTransitionsFromCancellingToCancelledAfterTrackedTaskDrains() async throws {
        let harness = TaskManagerHarness()
        let started = Expectation()
        let cancelled = Expectation()
        let timeout: UInt64 = 5_000_000_000

        let waiter = Task {
            try await harness.request(
                identifier: "tracked",
                started: started,
                cancelled: cancelled
            )
        }

        try await started.await(nanoseconds: timeout)

        await harness.cancelWithError(TaskManagerFailure.boom)

        #expect(await harness.stateSnapshot() == .cancellingBoom)

        do {
            _ = try await waiter.value
            Issue.record("Expected active waiter to receive the latched system error")
        } catch let error as TaskManagerFailure {
            #expect(error == .boom)
        } catch {
            Issue.record("Unexpected waiter error: \(error)")
        }

        try await cancelled.await(nanoseconds: timeout)

        #expect(await harness.stateSnapshot() == .cancelledBoom)
    }
}
