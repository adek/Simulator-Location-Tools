import Foundation

protocol SimulatorServicing: Sendable {
    func bootedDevices() async throws -> [SimulatorDevice]
    func setLocation(latitude: Double, longitude: Double, deviceID: String) async throws
    func clearLocation(deviceID: String) async throws
    func startRoute(points: [RoutePoint], speed: Double, deviceID: String) async throws
}

enum SimulatorServiceError: LocalizedError, Equatable {
    case commandFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .invalidResponse: "Simulator returned data that Simulator Location Tools could not read. Try updating or reselecting Xcode."
        }
    }
}

actor SimulatorService: SimulatorServicing {
    private let runner: any CommandRunning
    private let xcrunPath: String

    init(runner: any CommandRunning = ProcessCommandRunner(), xcrunPath: String = "/usr/bin/xcrun") {
        self.runner = runner
        self.xcrunPath = xcrunPath
    }

    func bootedDevices() async throws -> [SimulatorDevice] {
        let result = try await runner.run(executable: xcrunPath, arguments: ["simctl", "list", "devices", "--json"])
        guard result.exitCode == 0 else { throw commandError(from: result) }
        return try Self.parseBootedDevices(from: result.standardOutput)
    }

    func setLocation(latitude: Double, longitude: Double, deviceID: String) async throws {
        let coordinate = "\(CoordinateParser.commandString(latitude)),\(CoordinateParser.commandString(longitude))"
        let result = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "location", deviceID, "set", coordinate]
        )
        guard result.exitCode == 0 else { throw commandError(from: result) }
    }

    func clearLocation(deviceID: String) async throws {
        let result = try await runner.run(
            executable: xcrunPath,
            arguments: ["simctl", "location", deviceID, "clear"]
        )
        guard result.exitCode == 0 else { throw commandError(from: result) }
    }

    func startRoute(points: [RoutePoint], speed: Double, deviceID: String) async throws {
        guard points.count >= 2 else { throw SimulatorServiceError.commandFailed("A route needs at least two points.") }
        let input = points.map {
            "\(CoordinateParser.commandString($0.latitude)),\(CoordinateParser.commandString($0.longitude))"
        }.joined(separator: "\n") + "\n"
        let result = try await runner.run(
            executable: xcrunPath,
            arguments: [
                "simctl", "location", deviceID, "start",
                "--speed=\(CoordinateParser.commandString(max(speed, 0.1)))",
                "--interval=1", "-"
            ],
            standardInput: Data(input.utf8)
        )
        guard result.exitCode == 0 else { throw commandError(from: result) }
    }

    nonisolated static func parseBootedDevices(from data: Data) throws -> [SimulatorDevice] {
        struct Response: Decodable { let devices: [String: [Device]] }
        struct Device: Decodable { let name: String; let udid: String; let state: String; let isAvailable: Bool? }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw SimulatorServiceError.invalidResponse
        }

        var booted: [SimulatorDevice] = []
        for (runtimeIdentifier, devices) in response.devices {
            let runtimeName = readableRuntime(runtimeIdentifier)
            for device in devices where device.state == "Booted" && device.isAvailable != false {
                booted.append(SimulatorDevice(
                    udid: device.udid,
                    name: device.name,
                    runtime: runtimeName,
                    state: device.state
                ))
            }
        }
        return booted.sorted { lhs, rhs in
            lhs.runtime == rhs.runtime ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.runtime > rhs.runtime
        }
    }

    private nonisolated static func readableRuntime(_ identifier: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        let value = identifier.hasPrefix(prefix) ? String(identifier.dropFirst(prefix.count)) : identifier
        let pieces = value.split(separator: "-")
        guard pieces.count > 1 else { return value.replacingOccurrences(of: "-", with: " ") }
        let version = pieces.dropFirst().joined(separator: ".")
        return "\(pieces[0]) \(version)"
    }

    private nonisolated func commandError(from result: CommandResult) -> SimulatorServiceError {
        let raw = result.errorText.isEmpty ? result.outputText : result.errorText
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "simctl failed with exit code \(result.exitCode)."
        return .commandFailed(trimmed.isEmpty ? fallback : trimmed)
    }
}
