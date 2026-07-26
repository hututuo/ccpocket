import Foundation

/// Runs a child process while draining its output concurrently with waiting
/// for exit.
///
/// Reading the pipe only after `waitUntilExit()` deadlocks once the child
/// produces more than the ~64 KB pipe buffer (e.g. `brew install`,
/// `npm install -g`): the child blocks on write, the parent blocks on exit.
enum ProcessRunner {
    struct RunResult: Sendable {
        let terminationStatus: Int32
        let output: Data
    }

    static func run(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval,
        mergeStandardError: Bool = true
    ) async throws -> RunResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = mergeStandardError ? pipe : FileHandle.nullDevice

            let collector = OutputCollector()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    collector.finish()
                } else {
                    collector.append(chunk)
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { process.terminate() }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()

            // After exit the remaining buffered output and EOF arrive almost
            // immediately; the bound only guards against a stray grandchild
            // holding the write end open forever.
            let output = collector.waitForEOF(timeoutSeconds: 10)
            continuation.resume(returning: RunResult(
                terminationStatus: process.terminationStatus,
                output: output
            ))
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let eof = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func finish() {
        eof.signal()
    }

    func waitForEOF(timeoutSeconds: TimeInterval) -> Data {
        _ = eof.wait(timeout: .now() + timeoutSeconds)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
