import Foundation

struct CommandResult: Sendable, Equatable {
    let standardOutput: Data
    let standardError: Data
    let exitCode: Int32

    var outputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var errorText: String { String(decoding: standardError, as: UTF8.self) }
}

protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String], standardInput: Data?) async throws -> CommandResult
}

extension CommandRunning {
    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, standardInput: nil)
    }
}

enum CommandRunnerError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message): "Could not launch xcrun: \(message)"
        }
    }
}

final class ProcessCommandRunner: CommandRunning, @unchecked Sendable {
    func run(executable: String, arguments: [String], standardInput: Data?) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = standardInput == nil ? nil : Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            process.standardInput = inputPipe

            do {
                try process.run()
            } catch {
                throw CommandRunnerError.launchFailed(error.localizedDescription)
            }
            if let standardInput, let inputPipe {
                inputPipe.fileHandleForWriting.write(standardInput)
                try? inputPipe.fileHandleForWriting.close()
            }

            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CommandResult(standardOutput: output, standardError: error, exitCode: process.terminationStatus)
        }.value
    }
}
