import Foundation

nonisolated enum ExternalToolRunner {
    static func executableURL(named name: String) -> URL? {
        [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        outputHandler: (@Sendable (String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let box = ExternalProcessBox()
        box.process.executableURL = executable
        box.process.arguments = arguments
        box.process.environment = mergedEnvironment(environment)

        let outputPipe = Pipe()
        box.process.standardOutput = outputPipe
        box.process.standardError = outputPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.install(continuation)
                if let outputHandler {
                    outputPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                        outputHandler(chunk)
                    }
                }

                box.process.terminationHandler = { process in
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    box.finish(exitCode: process.terminationStatus, toolName: executable.lastPathComponent)
                }

                do {
                    try box.start()
                } catch is CancellationError {
                    box.failOnce(CancellationError())
                } catch {
                    box.failOnce(CryptaError.subtitleToolUnavailable(executable.lastPathComponent))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func runAndWait(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CryptaError.subtitleGenerationFailed("\(executable.lastPathComponent) exit \(process.terminationStatus)")
        }
    }

    static func runCapture(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(nil)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CryptaError.subtitleGenerationFailed("\(executable.lastPathComponent) exit \(process.terminationStatus)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func mergedEnvironment(_ overrides: [String: String]?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let overrides {
            environment.merge(overrides) { _, new in new }
        }
        return environment
    }
}

nonisolated private final class ExternalProcessBox: @unchecked Sendable {
    let process = Process()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var cancellationRequested = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        objc_sync_enter(self)
        self.continuation = continuation
        objc_sync_exit(self)
    }

    func start() throws {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard !cancellationRequested else { throw CancellationError() }
        try process.run()
    }

    func finish(exitCode: Int32, toolName: String) {
        resumeOnce {
            if self.cancellationRequested || exitCode == 143 {
                self.continuation?.resume(throwing: CancellationError())
            } else if exitCode == 0 {
                self.continuation?.resume()
            } else {
                self.continuation?.resume(throwing: CryptaError.subtitleGenerationFailed("\(toolName) exit \(exitCode)"))
            }
        }
    }

    func cancel() {
        objc_sync_enter(self)
        cancellationRequested = true
        let shouldTerminate = process.isRunning
        objc_sync_exit(self)
        if shouldTerminate {
            process.terminate()
        }
    }

    func failOnce(_ error: Error) {
        resumeOnce {
            self.continuation?.resume(throwing: error)
        }
    }

    private func resumeOnce(_ block: () -> Void) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        guard !finished else { return }
        finished = true
        block()
        continuation = nil
    }
}
