import Foundation
import Observation

@MainActor
@Observable
final class RoutePlaybackModel {
    enum DrivingProfile: String, CaseIterable, Identifiable {
        case constant
        case accelerate
        case variable50To100

        var id: Self { self }
        var label: String {
            switch self {
            case .constant: "Constant"
            case .accelerate: "Accelerate"
            case .variable50To100: "50–100"
            }
        }
    }

    enum State: Equatable {
        case idle
        case playing
        case stopping
        case completed
    }

    var state: State = .idle
    var speedMultiplier = 1.0
    var drivingProfile: DrivingProfile = .constant
    var repeatPlayback = false
    var elapsed: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var commandedSpeed: Double = 0
    var distanceTravelled: Double = 0
    var currentPoint: RoutePoint?
    var activeRouteID: UUID?
    var notice: AppModel.Notice?

    @ObservationIgnored private let service: any SimulatorServicing
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var activePoints: [RoutePoint] = []
    @ObservationIgnored private var cumulativeDistances: [Double] = []
    @ObservationIgnored private var activeDevices: [SimulatorDevice] = []
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var completedElapsed: TimeInterval = 0
    @ObservationIgnored private var distanceOffset: Double = 0
    @ObservationIgnored private var totalDistance: Double = 0
    @ObservationIgnored private var lastDynamicUpdate: Date?
    @ObservationIgnored private var dynamicElapsed: TimeInterval = 0
    @ObservationIgnored private var variableSpeedDirection = 1.0

    init(service: any SimulatorServicing = SimulatorService()) {
        self.service = service
    }

    var isPlaying: Bool { state == .playing || state == .stopping }
    var progress: Double { totalDistance > 0 ? min(max(distanceTravelled / totalDistance, 0), 1) : 0 }
    var remaining: TimeInterval { max(totalDuration - elapsed, 0) }

    func play(route: SavedRoute, devices: [SimulatorDevice]) {
        guard devices.isEmpty == false else {
            notice = AppModel.Notice(kind: .warning, message: "Select at least one booted simulator.")
            return
        }
        let points = route.points
        guard points.count >= 2 else {
            notice = AppModel.Notice(kind: .error, message: "This saved route has fewer than two usable points.")
            return
        }

        timerTask?.cancel()
        commandTask?.cancel()
        sessionID = UUID()
        activeRouteID = route.id
        activePoints = points
        activeDevices = devices
        cumulativeDistances = Self.cumulativeDistances(for: points)
        totalDistance = cumulativeDistances.last ?? 0
        commandedSpeed = initialSpeed()
        totalDuration = estimatedDuration(distance: totalDistance)
        elapsed = 0
        completedElapsed = 0
        distanceOffset = 0
        distanceTravelled = 0
        currentPoint = points.first
        startedAt = .now
        lastDynamicUpdate = .now
        dynamicElapsed = 0
        variableSpeedDirection = 1
        state = .playing
        notice = AppModel.Notice(
            kind: .success,
            message: "Playing \(route.name) on \(devices.count) simulator\(devices.count == 1 ? "" : "s")."
        )
        launchPlayback(points: activePoints, session: sessionID)
    }

    func changeProfile(to profile: DrivingProfile) {
        guard state != .playing else { return }
        drivingProfile = profile
        commandedSpeed = initialSpeed()
    }

    func changeSpeed(to multiplier: Double) async {
        let normalized = min(max(multiplier.rounded(), 1), 4)
        guard normalized != speedMultiplier else { return }
        guard state == .playing else {
            speedMultiplier = normalized
            commandedSpeed = initialSpeed()
            return
        }

        if drivingProfile == .accelerate {
            speedMultiplier = normalized
            notice = AppModel.Notice(kind: .success, message: "Accelerating toward \(Int(normalized * 50)) km/h.")
            return
        }
        guard drivingProfile == .constant else { return }

        updateProgress()
        speedMultiplier = normalized
        commandedSpeed = Self.speed(for: normalized)
        completedElapsed = elapsed
        distanceOffset = distanceTravelled
        totalDuration = elapsed + max(totalDistance - distanceTravelled, 0) / commandedSpeed

        let remainingPoints = remainingRoutePoints()
        let restartSession = UUID()
        sessionID = restartSession
        timerTask?.cancel()
        commandTask?.cancel()
        _ = await clear(devices: activeDevices)
        guard sessionID == restartSession, state == .playing else { return }

        startedAt = .now
        launchPlayback(points: remainingPoints, session: restartSession)
        notice = AppModel.Notice(
            kind: .success,
            message: "Playback speed changed to \(Int(normalized * 50)) km/h."
        )
    }

    func stop() async {
        guard state != .idle else { return }
        let devices = activeDevices
        sessionID = UUID()
        timerTask?.cancel()
        commandTask?.cancel()
        state = .stopping
        let failures = await clear(devices: devices)
        state = .idle
        activeRouteID = nil
        activePoints = []
        activeDevices = []
        cumulativeDistances = []
        currentPoint = nil
        elapsed = 0
        completedElapsed = 0
        distanceOffset = 0
        distanceTravelled = 0
        totalDistance = 0
        dynamicElapsed = 0
        lastDynamicUpdate = nil
        variableSpeedDirection = 1
        if failures.isEmpty {
            notice = AppModel.Notice(kind: .success, message: "Route playback stopped and simulated location cleared.")
        } else {
            notice = AppModel.Notice(kind: .warning, message: failures.joined(separator: "\n"))
        }
    }

    private func launchCommands(points: [RoutePoint], session: UUID) {
        let devices = activeDevices
        let speed = commandedSpeed
        let service = service
        commandTask = Task { [weak self] in
            let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                for device in devices {
                    group.addTask {
                        do {
                            try await service.startRoute(points: points, speed: speed, deviceID: device.udid)
                            return nil
                        } catch {
                            return "\(device.name): \(error.localizedDescription)"
                        }
                    }
                }
                var failures: [String] = []
                for await failure in group {
                    if let failure { failures.append(failure) }
                }
                return failures
            }
            guard let self, self.sessionID == session, failures.isEmpty == false else { return }
            self.notice = AppModel.Notice(kind: .warning, message: failures.joined(separator: "\n"))
        }
    }

    private func launchPlayback(points: [RoutePoint], session: UUID) {
        switch drivingProfile {
        case .constant:
            launchCommands(points: points, session: session)
            launchConstantTimer(session: session)
        case .accelerate, .variable50To100:
            launchDynamicTimer(session: session)
        }
    }

    private func launchConstantTimer(session: UUID) {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.sessionID == session, self.state == .playing else { return }
                self.updateProgress()
                if self.elapsed >= self.totalDuration {
                    if self.repeatPlayback {
                        await self.repeatRoute(session: session)
                    } else {
                        self.state = .completed
                        self.currentPoint = self.activePoints.last
                        self.notice = AppModel.Notice(kind: .success, message: "Route playback completed. The simulator remains at the destination.")
                        return
                    }
                }
            }
        }
    }

    private func launchDynamicTimer(session: UUID) {
        timerTask = Task { [weak self] in
            guard let self else { return }
            await self.sendDynamicLocation(session: session)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard self.sessionID == session, self.state == .playing else { return }
                self.updateDynamicProgress()
                await self.sendDynamicLocation(session: session)
                if self.distanceTravelled >= self.totalDistance {
                    if self.repeatPlayback {
                        await self.repeatRoute(session: session)
                    } else {
                        self.state = .completed
                        self.currentPoint = self.activePoints.last
                        self.notice = AppModel.Notice(kind: .success, message: "Route playback completed. The simulator remains at the destination.")
                    }
                    return
                }
            }
        }
    }

    private func repeatRoute(session: UUID) async {
        guard sessionID == session else { return }
        _ = await clear(devices: activeDevices)
        elapsed = 0
        completedElapsed = 0
        distanceOffset = 0
        distanceTravelled = 0
        dynamicElapsed = 0
        variableSpeedDirection = 1
        commandedSpeed = initialSpeed()
        totalDuration = estimatedDuration(distance: totalDistance)
        currentPoint = activePoints.first
        startedAt = .now
        lastDynamicUpdate = .now
        launchPlayback(points: activePoints, session: session)
    }

    private func updateProgress() {
        let segmentElapsed = Date.now.timeIntervalSince(startedAt ?? .now)
        elapsed = min(completedElapsed + segmentElapsed, totalDuration)
        distanceTravelled = min(distanceOffset + segmentElapsed * commandedSpeed, totalDistance)
        currentPoint = interpolatedPoint(at: distanceTravelled)
    }

    private func updateDynamicProgress() {
        let now = Date.now
        let delta = max(now.timeIntervalSince(lastDynamicUpdate ?? now), 0)
        lastDynamicUpdate = now
        dynamicElapsed += delta
        elapsed += delta

        let previousSpeed = commandedSpeed
        switch drivingProfile {
        case .constant:
            commandedSpeed = Self.speed(for: speedMultiplier)
        case .accelerate:
            let target = Self.speed(for: speedMultiplier)
            let change = (5 / 3.6) * delta
            if commandedSpeed < target { commandedSpeed = min(commandedSpeed + change, target) }
            else { commandedSpeed = max(commandedSpeed - change, target) }
        case .variable50To100:
            var kilometersPerHour = commandedSpeed * 3.6 + variableSpeedDirection * 5 * delta
            if kilometersPerHour >= 100 {
                kilometersPerHour = 100
                variableSpeedDirection = -1
            } else if kilometersPerHour <= 50 {
                kilometersPerHour = 50
                variableSpeedDirection = 1
            }
            commandedSpeed = kilometersPerHour / 3.6
        }

        distanceTravelled = min(
            distanceTravelled + ((previousSpeed + commandedSpeed) / 2) * delta,
            totalDistance
        )
        currentPoint = interpolatedPoint(at: distanceTravelled)
        totalDuration = elapsed + estimatedDuration(distance: max(totalDistance - distanceTravelled, 0))
    }

    private func sendDynamicLocation(session: UUID) async {
        guard sessionID == session, let point = currentPoint else { return }
        let devices = activeDevices
        let service = service
        let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for device in devices {
                group.addTask {
                    do {
                        try await service.setLocation(latitude: point.latitude, longitude: point.longitude, deviceID: device.udid)
                        return nil
                    } catch {
                        return "\(device.name): \(error.localizedDescription)"
                    }
                }
            }
            var failures: [String] = []
            for await failure in group {
                if let failure { failures.append(failure) }
            }
            return failures
        }
        guard sessionID == session, !failures.isEmpty else { return }
        notice = AppModel.Notice(kind: .warning, message: failures.joined(separator: "\n"))
    }

    private func remainingRoutePoints() -> [RoutePoint] {
        guard let currentPoint,
              let upperIndex = cumulativeDistances.firstIndex(where: { $0 >= distanceTravelled }) else {
            return activePoints
        }
        var points = [currentPoint]
        points.append(contentsOf: activePoints[upperIndex...])
        if points.count == 1, let last = activePoints.last { points.append(last) }
        return points
    }

    private func clear(devices: [SimulatorDevice]) async -> [String] {
        let service = service
        return await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for device in devices {
                group.addTask {
                    do {
                        try await service.clearLocation(deviceID: device.udid)
                        return nil
                    } catch {
                        return "\(device.name): \(error.localizedDescription)"
                    }
                }
            }
            var failures: [String] = []
            for await failure in group {
                if let failure { failures.append(failure) }
            }
            return failures
        }
    }

    private func interpolatedPoint(at distance: Double) -> RoutePoint? {
        guard let lastDistance = cumulativeDistances.last, lastDistance > 0 else { return activePoints.last }
        let target = min(max(distance, 0), lastDistance)
        guard let upperIndex = cumulativeDistances.firstIndex(where: { $0 >= target }) else { return activePoints.last }
        guard upperIndex > 0 else { return activePoints.first }
        let lowerIndex = upperIndex - 1
        let lowerDistance = cumulativeDistances[lowerIndex]
        let segmentDistance = cumulativeDistances[upperIndex] - lowerDistance
        let fraction = segmentDistance > 0 ? (target - lowerDistance) / segmentDistance : 0
        let lower = activePoints[lowerIndex]
        let upper = activePoints[upperIndex]
        let elevation: Double?
        if let a = lower.elevation, let b = upper.elevation { elevation = a + (b - a) * fraction }
        else { elevation = lower.elevation ?? upper.elevation }
        return RoutePoint(
            latitude: lower.latitude + (upper.latitude - lower.latitude) * fraction,
            longitude: lower.longitude + (upper.longitude - lower.longitude) * fraction,
            elevation: elevation
        )
    }

    private static func cumulativeDistances(for points: [RoutePoint]) -> [Double] {
        guard points.isEmpty == false else { return [] }
        var result = [0.0]
        for pair in zip(points, points.dropFirst()) {
            result.append((result.last ?? 0) + pair.0.location.distance(from: pair.1.location))
        }
        return result
    }

    private static func speed(for multiplier: Double) -> Double {
        multiplier * 50 / 3.6
    }

    private func initialSpeed() -> Double {
        switch drivingProfile {
        case .constant: Self.speed(for: speedMultiplier)
        case .accelerate: 10 / 3.6
        case .variable50To100: 50 / 3.6
        }
    }

    private func estimatedDuration(distance: Double) -> TimeInterval {
        let estimateSpeed: Double
        switch drivingProfile {
        case .constant: estimateSpeed = Self.speed(for: speedMultiplier)
        case .accelerate: estimateSpeed = max(Self.speed(for: speedMultiplier) * 0.75, 10 / 3.6)
        case .variable50To100: estimateSpeed = 75 / 3.6
        }
        return distance / estimateSpeed
    }
}
