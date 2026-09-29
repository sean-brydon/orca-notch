import Foundation

/// Thin wrapper around the `orca` CLI. Every call is `--json` and targets either the
/// local Orca runtime (`environment == nil`) or a paired remote environment by name.
enum OrcaCLI {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let executablePath: String = {
        let candidates = [
            "/usr/local/bin/orca",
            "/opt/homebrew/bin/orca",
            "/Applications/Orca.app/Contents/Resources/bin/orca",
            NSHomeDirectory() + "/Applications/Orca.app/Contents/Resources/bin/orca",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }()

    static func run(_ args: [String], environment: String?, timeout: TimeInterval = 8) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                var fullArgs = args
                if let environment { fullArgs += ["--environment", environment] }
                fullArgs.append("--json")
                process.arguments = fullArgs

                // Why: if this app is ever launched from inside an Orca terminal, inherited
                // ORCA_* vars would silently scope every call to that one pane/worktree.
                var env = ProcessInfo.processInfo.environment
                for key in env.keys where key.hasPrefix("ORCA_") { env.removeValue(forKey: key) }
                process.environment = env

                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: Failure(message: "Can't run orca CLI at \(executablePath)"))
                    return
                }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: data)
            }
        }
    }

    static func call<T: Decodable>(_ type: T.Type, _ args: [String], environment: String?, timeout: TimeInterval = 8) async throws -> T {
        let data = try await run(args, environment: environment, timeout: timeout)
        guard !data.isEmpty else { throw Failure(message: "No response (timed out?)") }
        let envelope: Envelope<T>
        do {
            envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw Failure(message: "Unexpected orca output: \(error)")
        }
        guard envelope.ok, let result = envelope.result else {
            throw Failure(message: envelope.error?.message ?? "orca returned ok=false")
        }
        return result
    }

    // MARK: - Commands

    static func environments() async throws -> [OrcaEnvironment] {
        try await call(EnvironmentList.self, ["environment", "list"], environment: nil).environments
    }

    static func worktrees(environment: String?) async throws -> [Worktree] {
        try await call(WorktreePS.self, ["worktree", "ps"], environment: environment).worktrees
    }

    static func terminals(environment: String?) async throws -> [TerminalRow] {
        try await call(TerminalList.self, ["terminal", "list"], environment: environment).terminals
    }

    static func screen(handle: String, environment: String?) async throws -> TerminalScreen {
        try await call(TerminalRead.self, ["terminal", "read", "--terminal", handle, "--screen"],
                       environment: environment, timeout: 5).terminal
    }

    static func send(handle: String, text: String, enter: Bool, environment: String?) async throws {
        var args = ["terminal", "send", "--terminal", handle, "--text", text]
        if enter { args.append("--enter") }
        _ = try await call(JSONValue.self, args, environment: environment)
    }

    static func focus(handle: String, environment: String?) async throws {
        _ = try await call(JSONValue.self, ["terminal", "switch", "--terminal", handle], environment: environment)
    }
}
