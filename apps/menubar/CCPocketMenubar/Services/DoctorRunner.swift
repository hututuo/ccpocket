import Foundation

/// Runs Bridge doctor checks, trying HTTP first then falling back to CLI.
final class DoctorRunner: Sendable {
    private let bridgeClient: BridgeClient
    private let processManager: BridgeProcessManager

    init(bridgeClient: BridgeClient = BridgeClient(),
         processManager: BridgeProcessManager = BridgeProcessManager()) {
        self.bridgeClient = bridgeClient
        self.processManager = processManager
    }

    /// Run doctor checks. Tries Bridge HTTP endpoint first, falls back to CLI.
    func runDoctor() async throws -> DoctorReport {
        // Try HTTP endpoint first (if Bridge is running)
        if let report = try? await bridgeClient.doctor() {
            return report
        }

        // Fall back to CLI
        return try await runDoctorCLI()
    }

    /// Run `ccpocket-bridge doctor --json` via CLI.
    private func runDoctorCLI() async throws -> DoctorReport {
        let result = try await ProcessRunner.run(
            executablePath: "/bin/zsh",
            arguments: ["-li", "-c", "npx --yes @ccpocket/bridge@latest doctor --json"],
            timeout: 60,
            mergeStandardError: false
        )

        do {
            return try JSONDecoder().decode(DoctorReport.self, from: result.output)
        } catch {
            let output = String(data: result.output, encoding: .utf8) ?? "(no output)"
            throw DoctorError.parseFailed(output: output)
        }
    }
}

enum DoctorError: LocalizedError {
    case parseFailed(output: String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let output):
            return "Failed to parse doctor output: \(output.prefix(200))"
        }
    }
}
