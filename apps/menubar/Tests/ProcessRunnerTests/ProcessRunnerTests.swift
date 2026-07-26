import XCTest
@testable import ProcessRunnerKit

final class ProcessRunnerTests: XCTestCase {
    /// P0-10 regression: a child producing far more than the ~64 KB pipe
    /// buffer must not deadlock against waitUntilExit.
    func testLargeOutputDoesNotDeadlock() async throws {
        let result = try await withTimeout(seconds: 30) {
            try await ProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "head -c 2000000 /dev/zero"],
                timeout: 60
            )
        }
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.output.count, 2_000_000)
    }

    func testPropagatesExitStatusAndOutput() async throws {
        let result = try await withTimeout(seconds: 30) {
            try await ProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "echo out; echo err 1>&2; exit 3"],
                timeout: 60
            )
        }
        XCTAssertEqual(result.terminationStatus, 3)
        let text = String(data: result.output, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("out"))
        XCTAssertTrue(text.contains("err"))
    }

    func testStandardErrorCanBeDiscarded() async throws {
        let result = try await withTimeout(seconds: 30) {
            try await ProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "echo out; echo err 1>&2"],
                timeout: 60,
                mergeStandardError: false
            )
        }
        let text = String(data: result.output, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("out"))
        XCTAssertFalse(text.contains("err"))
    }

    func testTimeoutTerminatesChild() async throws {
        let start = Date()
        let result = try await withTimeout(seconds: 20) {
            try await ProcessRunner.run(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                timeout: 1
            )
        }
        XCTAssertNotEqual(result.terminationStatus, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
    }

    func testSpawnFailureThrows() async {
        do {
            _ = try await ProcessRunner.run(
                executablePath: "/nonexistent/binary",
                arguments: [],
                timeout: 5
            )
            XCTFail("expected spawn to throw")
        } catch {
            // expected
        }
    }
}

private struct TimedOut: Error {}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOut()
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
