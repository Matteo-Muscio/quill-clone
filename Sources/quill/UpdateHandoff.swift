import Foundation

/// A PID-addressed, cooperative request. Older versions do not observe this
/// notification, so an updater cannot accidentally stop one mid-recording.
@MainActor
final class UpdateHandoff {
    nonisolated static let notificationName = Notification.Name("com.digimata.quill.prepareForUpdate")

    private let beginReservation: () -> Bool
    private let reserveCoordinator: @MainActor () async -> Bool
    private let releaseReservation: () -> Void
    private let terminate: () -> Void
    private var requested = false
    private var observer: UpdateNotificationObserver?

    init(
        beginReservation: @escaping () -> Bool,
        reserveCoordinator: @escaping @MainActor () async -> Bool,
        releaseReservation: @escaping () -> Void,
        terminate: @escaping () -> Void
    ) {
        self.beginReservation = beginReservation
        self.reserveCoordinator = reserveCoordinator
        self.releaseReservation = releaseReservation
        self.terminate = terminate
    }

    func startObserving(processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        guard observer == nil else { return }
        observer = UpdateNotificationObserver(processID: processID) { [weak self] in
            Task { @MainActor [weak self] in await self?.request() }
        }
    }

    /// Ignore busy requests; the invoking updater retries within its deadline.
    /// Lock main-actor actions before yielding to the transcription actor.
    func request() async {
        guard !requested, beginReservation() else { return }
        requested = true
        guard await reserveCoordinator() else {
            releaseReservation()
            requested = false
            return
        }
        terminate()
    }
}

/// The token is immutable after construction and only removed on destruction.
private final class UpdateNotificationObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(processID: Int32, request: @escaping @Sendable () -> Void) {
        token = DistributedNotificationCenter.default().addObserver(
            forName: UpdateHandoff.notificationName,
            object: String(processID), queue: .main
        ) { _ in request() }
    }

    deinit { DistributedNotificationCenter.default().removeObserver(token) }
}

/// Count submissions synchronously, before their Tasks reach the coordinator.
/// This includes launch recovery and on_stop hooks with transcription disabled.
@MainActor
final class SubmittedCoordinatorWork {
    private(set) var pendingCount = 0

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        pendingCount += 1
        Task {
            await operation()
            pendingCount -= 1
        }
    }
}
