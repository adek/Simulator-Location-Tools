import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Activity: Equatable {
        case idle
        case refreshing
        case applying
        case clearing

        var isWorking: Bool { self != .idle }
    }

    struct Notice: Equatable {
        enum Kind: Equatable { case success, warning, error }
        let kind: Kind
        let message: String
    }

    private let simulatorService: any SimulatorServicing
    let catalog: LocationCatalog
    var devices: [SimulatorDevice] = []
    var selectedDeviceIDs: Set<String> = []
    var selectedCountryCode: String?
    var selectedLocationID: String?
    var searchText = ""
    var activity: Activity = .idle
    var notice: Notice?
    var lastRefresh: Date?

    init(
        simulatorService: any SimulatorServicing = SimulatorService(),
        catalog: LocationCatalog? = nil
    ) {
        self.simulatorService = simulatorService
        do {
            self.catalog = try catalog ?? LocationCatalog()
        } catch {
            self.catalog = LocationCatalog.empty
            notice = Notice(kind: .error, message: error.localizedDescription)
        }
    }

    func refreshDevices(showError: Bool = true) async {
        guard activity == .idle else { return }
        activity = .refreshing
        defer { activity = .idle }
        do {
            let refreshed = try await simulatorService.bootedDevices()
            devices = refreshed
            selectedDeviceIDs.formIntersection(Set(refreshed.map(\.id)))
            lastRefresh = .now
            if refreshed.isEmpty, showError {
                notice = Notice(kind: .warning, message: "No booted simulators. Open an iOS Simulator and refresh.")
            } else if notice?.kind != .error {
                notice = nil
            }
        } catch {
            devices = []
            selectedDeviceIDs.removeAll()
            if showError {
                notice = Notice(kind: .error, message: actionableMessage(for: error))
            }
        }
    }

    func apply(_ location: LocationChoice) async {
        let targets = selectedTargets()
        guard !targets.isEmpty else {
            notice = Notice(kind: .warning, message: "Select at least one booted simulator.")
            return
        }
        activity = .applying
        defer { activity = .idle }
        let failures = await execute(on: targets) { service, device in
            try await service.setLocation(latitude: location.latitude, longitude: location.longitude, deviceID: device.udid)
        }
        report(action: "Applied \(location.name)", targets: targets, failures: failures)
    }

    func clearLocation() async {
        let targets = selectedTargets()
        guard !targets.isEmpty else {
            notice = Notice(kind: .warning, message: "Select at least one booted simulator.")
            return
        }
        activity = .clearing
        defer { activity = .idle }
        let failures = await execute(on: targets) { service, device in
            try await service.clearLocation(deviceID: device.udid)
        }
        report(action: "Cleared simulated location", targets: targets, failures: failures)
    }

    private func selectedTargets() -> [SimulatorDevice] {
        devices.filter { selectedDeviceIDs.contains($0.id) }
    }

    private func execute(
        on targets: [SimulatorDevice],
        operation: (any SimulatorServicing, SimulatorDevice) async throws -> Void
    ) async -> [(SimulatorDevice, String)] {
        var failures: [(SimulatorDevice, String)] = []
        for device in targets {
            do { try await operation(simulatorService, device) }
            catch { failures.append((device, error.localizedDescription)) }
        }
        return failures
    }

    private func report(action: String, targets: [SimulatorDevice], failures: [(SimulatorDevice, String)]) {
        if failures.isEmpty {
            notice = Notice(kind: .success, message: "\(action) to \(targets.count) simulator\(targets.count == 1 ? "" : "s").")
        } else if failures.count == targets.count {
            notice = Notice(kind: .error, message: failures.map { "\($0.0.name): \($0.1)" }.joined(separator: "\n"))
        } else {
            let succeeded = targets.count - failures.count
            let details = failures.map { "\($0.0.name): \($0.1)" }.joined(separator: "\n")
            notice = Notice(kind: .warning, message: "Succeeded on \(succeeded) of \(targets.count) simulators.\n\(details)")
        }
    }

    private func actionableMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("xcode") || message.localizedCaseInsensitiveContains("developer") {
            return "\(message)\nSelect the active Xcode in Xcode Settings or with xcode-select."
        }
        if message.localizedCaseInsensitiveContains("CoreSimulator") || message.localizedCaseInsensitiveContains("device set") {
            return "\(message)\nOpen Simulator from Xcode, then try Refresh again."
        }
        return message
    }
}

extension LocationCatalog {
    fileprivate static var empty: LocationCatalog {
        try! LocationCatalog(data: Data("[]".utf8))
    }
}
