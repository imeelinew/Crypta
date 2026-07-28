import AppKit

@MainActor
final class ExternalMediaApplicationController {
    enum Target: Equatable {
        case iina
        case pixea

        var bundleIdentifier: String {
            switch self {
            case .iina: return "com.colliderli.iina"
            case .pixea: return "imagetasks.Pixea"
            }
        }
    }

    private var leases: [pid_t: [DecryptedMediaLease]] = [:]
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let application else { return }
                self?.releaseLeases(for: application.processIdentifier)
            }
        }
    }

    func open(_ lease: DecryptedMediaLease, with target: Target) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleIdentifier) else {
            throw CryptaError.externalPlayerUnavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let application = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
            NSWorkspace.shared.open(
                [lease.url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { application, error in
                if error != nil || application == nil {
                    continuation.resume(throwing: CryptaError.externalPlayerOpenFailed)
                } else if let application {
                    continuation.resume(returning: application)
                }
            }
        }

        let processIdentifier = application.processIdentifier
        leases[processIdentifier, default: []].append(lease)
        if application.isTerminated {
            releaseLeases(for: processIdentifier)
        }
    }

    private func releaseLeases(for processIdentifier: pid_t) {
        guard let retainedLeases = leases.removeValue(forKey: processIdentifier) else { return }
        for lease in retainedLeases {
            lease.release()
        }
    }
}
