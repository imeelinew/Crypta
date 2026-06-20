import Foundation

nonisolated enum SubtitleProcessRunner {
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
        let box = ProcessBox()
        box.process.executableURL = executable
        box.process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let environment {
            env.merge(environment) { _, new in new }
        }
        box.process.environment = env

        let outputPipe = Pipe()
        box.process.standardOutput = outputPipe
        box.process.standardError = outputPipe

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation
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
                    try box.process.run()
                } catch {
                    box.failOnce(CryptaError.subtitleToolUnavailable(executable.lastPathComponent))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func runCapture(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CryptaError.subtitleGenerationFailed("\(executable.lastPathComponent) exit \(process.terminationStatus)")
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

nonisolated private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    var continuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private var cancellationRequested = false

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
