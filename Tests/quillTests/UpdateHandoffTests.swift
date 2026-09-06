import XCTest
@testable import quill

@MainActor
final class UpdateHandoffTests: XCTestCase {
    func testBusyRequestDoesNotReserveOrTerminateAndCanBeRetried() async {
        var busy = true
        var reservations = 0
        var exits = 0
        let handoff = UpdateHandoff(
            beginReservation: { !busy },
            reserveCoordinator: { reservations += 1; return true },
            releaseReservation: { XCTFail("Unexpected release") },
            terminate: { exits += 1 }
        )
        await handoff.request()
        XCTAssertEqual(reservations, 0)
        XCTAssertEqual(exits, 0)
        busy = false
        await handoff.request()
        XCTAssertEqual(reservations, 1)
        XCTAssertEqual(exits, 1)
    }

    func testCoordinatorRefusalReleasesActionsAndAllowsLaterRequest() async {
        var state = AppBusyState()
        var reservationAttempts = 0
        var exits = 0
        let handoff = UpdateHandoff(
            beginReservation: {
                guard state.canPrepareUpdate else { return false }
                state.isPreparingUpdate = true
                return true
            },
            reserveCoordinator: {
                reservationAttempts += 1
                return reservationAttempts > 1
            },
            releaseReservation: { state.isPreparingUpdate = false },
            terminate: { exits += 1 }
        )
        await handoff.request()
        XCTAssertTrue(state.canStartRecording)
        XCTAssertTrue(state.canRetryTranscription)
        XCTAssertFalse(state.modelActionsLocked)
        XCTAssertEqual(exits, 0)
        await handoff.request()
        XCTAssertEqual(exits, 1)
    }

    func testActionsStayLockedAcrossSuspensionAndDuplicateRequestsExitOnlyOnce() async {
        var state = AppBusyState()
        var reservations = 0
        var exits = 0
        let gate = HandoffGate()
        let handoff = UpdateHandoff(
            beginReservation: {
                guard state.canPrepareUpdate else { return false }
                state.isPreparingUpdate = true
                return true
            },
            reserveCoordinator: {
                reservations += 1
                await gate.wait()
                return true
            },
            releaseReservation: { XCTFail("Unexpected release") },
            terminate: { exits += 1 }
        )
        let firstRequest = Task { await handoff.request() }
        await gate.waitUntilEntered()
        XCTAssertFalse(state.canStartRecording)
        XCTAssertFalse(state.canRetryTranscription)
        XCTAssertTrue(state.modelActionsLocked)
        await handoff.request()
        XCTAssertEqual(reservations, 1)
        XCTAssertEqual(exits, 0)
        await gate.open()
        await firstRequest.value
        await handoff.request()
        XCTAssertEqual(reservations, 1)
        XCTAssertEqual(exits, 1)
    }

    func testSubmittedWorkBlocksHandoffBeforeTaskStartsAndUntilOperationCompletes() async {
        let submitted = SubmittedCoordinatorWork()
        let gate = HandoffGate()
        var completed = false
        var exits = 0
        let handoff = UpdateHandoff(
            beginReservation: { submitted.pendingCount == 0 },
            reserveCoordinator: { true },
            releaseReservation: {},
            terminate: { exits += 1 }
        )
        // Same path as startup recovery and recording handoff, including when
        // transcription is disabled and enqueue must still launch on_stop.
        submitted.submit {
            await gate.wait()
            await MainActor.run { completed = true }
        }
        XCTAssertEqual(submitted.pendingCount, 1)
        await handoff.request()
        XCTAssertEqual(exits, 0)
        await gate.waitUntilEntered()
        await handoff.request()
        XCTAssertEqual(exits, 0)
        await gate.open()
        while submitted.pendingCount != 0 { await Task.yield() }
        XCTAssertTrue(completed)
        await handoff.request()
        XCTAssertEqual(exits, 1)
    }
}

private actor HandoffGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
