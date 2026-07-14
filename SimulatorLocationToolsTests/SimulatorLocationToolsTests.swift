import SwiftData
import XCTest
@testable import SimulatorLocationTools

final class SimulatorParsingTests: XCTestCase {
    func testParsesOnlyAvailableBootedDevicesAcrossRuntimes() throws {
        let json = Data(#"""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
              {"name":"iPhone 17 Pro","udid":"A","state":"Booted","isAvailable":true},
              {"name":"iPhone 16","udid":"B","state":"Shutdown","isAvailable":true}
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
              {"name":"iPhone SE","udid":"C","state":"Booted","isAvailable":true},
              {"name":"Unavailable","udid":"D","state":"Booted","isAvailable":false}
            ]
          }
        }
        """#.utf8)

        let devices = try SimulatorService.parseBootedDevices(from: json)

        XCTAssertEqual(Set(devices.map(\.udid)), ["A", "C"])
        XCTAssertEqual(devices.first(where: { $0.udid == "A" })?.runtime, "iOS 26.0")
    }

    func testEmptyDeviceDictionaryProducesEmptyList() throws {
        let devices = try SimulatorService.parseBootedDevices(from: Data(#"{"devices":{}}"#.utf8))
        XCTAssertTrue(devices.isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try SimulatorService.parseBootedDevices(from: Data("not-json".utf8)))
    }
}

final class SimulatorCommandTests: XCTestCase {
    func testSetAndClearUseExplicitUDIDAndNormalizedCoordinates() async throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0),
            CommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
        ])
        let service = SimulatorService(runner: runner)

        try await service.setLocation(latitude: 50.0614, longitude: 19.9383, deviceID: "DEVICE-1")
        try await service.clearLocation(deviceID: "DEVICE-1")

        let calls = await runner.calls
        XCTAssertEqual(calls[0].arguments, ["simctl", "location", "DEVICE-1", "set", "50.0614,19.9383"])
        XCTAssertEqual(calls[1].arguments, ["simctl", "location", "DEVICE-1", "clear"])
    }

    func testNonzeroExitIncludesSimctlError() async {
        let runner = RecordingCommandRunner(results: [
            CommandResult(standardOutput: Data(), standardError: Data("device not found".utf8), exitCode: 2)
        ])
        let service = SimulatorService(runner: runner)

        do {
            try await service.clearLocation(deviceID: "MISSING")
            XCTFail("Expected command failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("device not found"))
        }
    }

    func testRouteUsesStdinWithSpeedAndExplicitUDID() async throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(standardOutput: Data(), standardError: Data(), exitCode: 0)
        ])
        let service = SimulatorService(runner: runner)
        let points = [
            RoutePoint(latitude: 50.0614, longitude: 19.9383),
            RoutePoint(latitude: 50.07, longitude: 19.95)
        ]

        try await service.startRoute(points: points, speed: 27.5, deviceID: "DEVICE-2")

        let calls = await runner.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.arguments, ["simctl", "location", "DEVICE-2", "start", "--speed=27.5", "--interval=1", "-"])
        XCTAssertEqual(String(decoding: call.standardInput ?? Data(), as: UTF8.self), "50.0614,19.9383\n50.07,19.95\n")
    }
}

final class LocationDataTests: XCTestCase {
    func testStartupSelectionPrefersLastCountryThenFavoriteThenFirstCountry() {
        let countries = [(code: "DE", name: "Germany"), (code: "PL", name: "Poland")]

        XCTAssertEqual(StartupSelectionResolver.countryCode(
            lastCountryCode: "PL", favoriteCountryCodes: ["DE"], countries: countries
        ), "PL")
        XCTAssertEqual(StartupSelectionResolver.countryCode(
            lastCountryCode: "", favoriteCountryCodes: ["PL"], countries: countries
        ), "PL")
        XCTAssertEqual(StartupSelectionResolver.countryCode(
            lastCountryCode: "", favoriteCountryCodes: [], countries: countries
        ), "DE")
    }

    func testStartupSelectionRestoresAvailableLocationAndFallsBackWhenMissing() {
        let locations = ["preset:DE:Berlin", "preset:DE:Munich"]

        XCTAssertEqual(StartupSelectionResolver.locationID(
            lastLocationID: "preset:DE:Munich", availableLocationIDs: locations
        ), "preset:DE:Munich")
        XCTAssertEqual(StartupSelectionResolver.locationID(
            lastLocationID: "saved:deleted", availableLocationIDs: locations
        ), "preset:DE:Berlin")
    }

    func testCoordinateValidationAndLocaleParsing() {
        let polish = Locale(identifier: "pl_PL")
        let parsed = CoordinateParser.parse("50,0614", locale: polish)!
        XCTAssertEqual(parsed, 50.0614, accuracy: 0.000_001)
        XCTAssertNil(LocationValidation.validate(
            name: "Kraków", countryCode: "PL", latitude: 50.0614, longitude: 19.9383,
            knownCountryCodes: ["PL"]
        ))
        XCTAssertNotNil(LocationValidation.validate(
            name: "Invalid", countryCode: "PL", latitude: 91, longitude: 19,
            knownCountryCodes: ["PL"]
        ))
    }

    func testCatalogDecodingAndGrouping() throws {
        let data = Data(#"""
        [
          {"countryCode":"PL","countryName":"Poland","name":"Warsaw","latitude":52.2297,"longitude":21.0122},
          {"countryCode":"DE","countryName":"Germany","name":"Berlin","latitude":52.52,"longitude":13.405}
        ]
        """#.utf8)
        let catalog = try LocationCatalog(data: data)

        XCTAssertEqual(catalog.presets.count, 2)
        XCTAssertEqual(catalog.countries.map(\.code), ["DE", "PL"])
        XCTAssertEqual(catalog.presets.first(where: { $0.countryCode == "PL" })?.kind, .nationalCapital)
        XCTAssertEqual(catalog.presetsByCountry["PL"]?.map(\.name), ["Warsaw"])
        XCTAssertEqual(catalog.presetByID["PL:Warsaw"]?.latitude, 52.2297)
        XCTAssertEqual(catalog.countryNameByCode["DE"], "Germany")
        XCTAssertEqual(catalog.knownCountryCodes, ["DE", "PL"])
    }

    func testSupplementalCitiesHaveKindsAndCapitalsSortFirst() throws {
        let capitals = Data(#"""
        [{"countryCode":"US","countryName":"United States","name":"Washington, D.C.","latitude":38.9072,"longitude":-77.0369}]
        """#.utf8)
        let cities = Data(#"""
        [
          {"countryCode":"US","countryName":"United States","name":"New York City","latitude":40.71427,"longitude":-74.00597,"kind":"city"},
          {"countryCode":"US","countryName":"United States","name":"Albany","latitude":42.65258,"longitude":-73.75623,"kind":"stateCapital"}
        ]
        """#.utf8)

        let catalog = try LocationCatalog(data: capitals, supplementalData: cities)

        XCTAssertEqual(catalog.presets.map(\.name), ["Washington, D.C.", "Albany", "New York City"])
        XCTAssertEqual(catalog.presets.map(\.kind), [.nationalCapital, .stateCapital, .city])
    }

    func testBundledCatalogIncludesExpandedTestingMarkets() throws {
        let catalog = try LocationCatalog()
        let poland = catalog.presets.filter { $0.countryCode == "PL" }
        let germany = catalog.presets.filter { $0.countryCode == "DE" }
        let stateCapitals = catalog.presets.filter { $0.countryCode == "US" && $0.kind == .stateCapital }

        XCTAssertGreaterThanOrEqual(poland.count, 20)
        XCTAssertGreaterThanOrEqual(germany.count, 20)
        XCTAssertEqual(stateCapitals.count, 50)
        XCTAssertTrue(poland.contains { $0.name == "Kraków" && $0.kind == .city })
        XCTAssertTrue(germany.contains { $0.name == "Munich" && $0.kind == .city })
        XCTAssertEqual(Set(catalog.presets.map(\.id)).count, catalog.presets.count)
        XCTAssertTrue(catalog.presets.allSatisfy {
            (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
        })
    }

    @MainActor
    func testSavedLocationPersistsInMemory() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedLocation.self, configurations: configuration)
        let context = container.mainContext
        context.insert(SavedLocation(name: "Kraków", countryCode: "PL", latitude: 50.0614, longitude: 19.9383))
        try context.save()

        let saved = try context.fetch(FetchDescriptor<SavedLocation>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.countryCode, "PL")
    }

    @MainActor
    func testFavoriteCountryPersistsInMemory() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: FavoriteCountry.self, configurations: configuration)
        let context = container.mainContext
        context.insert(FavoriteCountry(countryCode: "PL"))
        try context.save()

        let favorites = try context.fetch(FetchDescriptor<FavoriteCountry>())
        XCTAssertEqual(favorites.map(\.countryCode), ["PL"])
    }

    @MainActor
    func testSavedRoutePreservesPointsAndMetadata() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedRoute.self, configurations: configuration)
        let context = container.mainContext
        let points = [
            RoutePoint(latitude: 50, longitude: 19, elevation: 220),
            RoutePoint(latitude: 51, longitude: 20, elevation: 240)
        ]
        let route = try SavedRoute(
            name: "Test", countryCode: "PL", destinationCountryCode: "PL",
            startName: "A", endName: "B", source: .gpx,
            distance: 1000, expectedTravelTime: 100, baseSpeed: 10, points: points
        )
        context.insert(route)
        try context.save()

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<SavedRoute>()).first)
        XCTAssertEqual(saved.points, points)
        XCTAssertEqual(saved.source, .gpx)
    }
}

final class GPXTests: XCTestCase {
    func testParsesTrackPointsElevationAndTimestamps() throws {
        let data = Data(#"""
        <?xml version="1.0"?>
        <gpx version="1.1"><wpt lat="1" lon="2"/><trk><name>Morning Drive</name><trkseg>
          <trkpt lat="50.0" lon="19.0"><ele>220.5</ele><time>2026-07-14T10:00:00Z</time></trkpt>
          <trkpt lat="50.1" lon="19.1"><ele>225.0</ele><time>2026-07-14T10:01:00Z</time></trkpt>
        </trkseg></trk></gpx>
        """#.utf8)

        let imported = try GPXParser.parse(data: data)

        XCTAssertEqual(imported.name, "Morning Drive")
        XCTAssertEqual(imported.points.count, 2)
        XCTAssertEqual(imported.points.first?.elevation, 220.5)
        XCTAssertNotNil(imported.points.first?.timestamp)
    }

    func testRejectsGPXWithFewerThanTwoPoints() {
        let data = Data(#"<gpx><wpt lat="50" lon="19"/></gpx>"#.utf8)
        XCTAssertThrowsError(try GPXParser.parse(data: data)) { error in
            XCTAssertEqual(error as? GPXError, .insufficientPoints)
        }
    }

    func testXcodeCompatibleExportCanBeParsedAgain() throws {
        let points = [RoutePoint(latitude: 50, longitude: 19, elevation: 200), RoutePoint(latitude: 51, longitude: 20)]
        let document = GPXFileDocument(routeName: "Export Test", points: points)
        let imported = try GPXParser.parse(data: document.encodedData())
        XCTAssertEqual(imported.points.count, 2)
        XCTAssertEqual(imported.points.first?.elevation, 200)
    }
}

final class AppModelTests: XCTestCase {
    @MainActor
    func testRefreshRemovesSelectionForSimulatorThatDisappeared() async throws {
        let a = SimulatorDevice(udid: "A", name: "iPhone A", runtime: "iOS 26.0", state: "Booted")
        let b = SimulatorDevice(udid: "B", name: "iPhone B", runtime: "iOS 26.0", state: "Booted")
        let service = MockSimulatorService(devices: [a, b])
        let model = AppModel(simulatorService: service, catalog: try testCatalog())

        await model.refreshDevices()
        model.selectedDeviceIDs = ["A", "B"]
        await service.setDevices([a])
        await model.refreshDevices()

        XCTAssertEqual(model.selectedDeviceIDs, ["A"])
    }

    @MainActor
    func testApplyReportsPartialFailureAndAttemptsEverySelectedDevice() async throws {
        let a = SimulatorDevice(udid: "A", name: "iPhone A", runtime: "iOS 26.0", state: "Booted")
        let b = SimulatorDevice(udid: "B", name: "iPhone B", runtime: "iOS 26.0", state: "Booted")
        let service = MockSimulatorService(devices: [a, b], failingDeviceIDs: ["B"])
        let model = AppModel(simulatorService: service, catalog: try testCatalog())
        await model.refreshDevices()
        model.selectedDeviceIDs = ["A", "B"]
        let location = LocationChoice(
            id: "test", name: "Kraków", countryCode: "PL", countryName: "Poland",
            latitude: 50.0614, longitude: 19.9383, source: .saved, presetKind: nil
        )

        await model.apply(location)

        let calls = await service.setCalls
        XCTAssertEqual(Set(calls), ["A", "B"])
        XCTAssertEqual(model.notice?.kind, .warning)
        XCTAssertTrue(model.notice?.message.contains("Succeeded on 1 of 2") == true)
    }

    private func testCatalog() throws -> LocationCatalog {
        try LocationCatalog(data: Data(#"""
        [{"countryCode":"PL","countryName":"Poland","name":"Warsaw","latitude":52.2297,"longitude":21.0122}]
        """#.utf8))
    }
}

final class RoutePlaybackTests: XCTestCase {
    @MainActor
    func testPlaybackUsesFixedSpeedsCanChangeLiveAndClearsOnStop() async throws {
        let service = MockSimulatorService(devices: [])
        let playback = RoutePlaybackModel(service: service)
        await playback.changeSpeed(to: 2)
        let route = try SavedRoute(
            name: "Short Route", countryCode: "PL", destinationCountryCode: "PL",
            startName: "Start", endName: "End", source: .calculated,
            distance: 111, expectedTravelTime: 11.1, baseSpeed: 10,
            points: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0.001, longitude: 0)]
        )
        let device = SimulatorDevice(udid: "A", name: "iPhone", runtime: "iOS 26", state: "Booted")

        playback.play(route: route, devices: [device])
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(playback.commandedSpeed, 100 / 3.6, accuracy: 0.001)
        XCTAssertGreaterThan(playback.progress, 0)
        XCTAssertGreaterThan(playback.currentPoint?.latitude ?? 0, 0)
        let progressBeforeChange = playback.progress

        await playback.changeSpeed(to: 4)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(playback.commandedSpeed, 200 / 3.6, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(playback.progress, progressBeforeChange)
        let starts = await service.routeCalls
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.first?.deviceID, "A")
        XCTAssertEqual(starts.first?.speed ?? 0, 100 / 3.6, accuracy: 0.001)
        XCTAssertEqual(starts.last?.speed ?? 0, 200 / 3.6, accuracy: 0.001)
        XCTAssertLessThanOrEqual(starts.last?.pointCount ?? .max, starts.first?.pointCount ?? 0)

        await playback.stop()
        XCTAssertEqual(playback.state, .idle)
        let clearCalls = await service.clearCalls
        XCTAssertEqual(clearCalls, ["A", "A"])
    }

    @MainActor
    func testSmoothAndVariableProfilesAdvanceSpeedGradually() async throws {
        let variableService = MockSimulatorService(devices: [])
        let accelerateService = MockSimulatorService(devices: [])
        let variable = RoutePlaybackModel(service: variableService)
        let accelerate = RoutePlaybackModel(service: accelerateService)
        variable.changeProfile(to: .variable50To100)
        await accelerate.changeSpeed(to: 2)
        accelerate.changeProfile(to: .accelerate)
        let route = try SavedRoute(
            name: "Dynamic Route", countryCode: "PL", destinationCountryCode: "PL",
            startName: "Start", endName: "End", source: .calculated,
            distance: 1_100, expectedTravelTime: 80, baseSpeed: 14,
            points: [RoutePoint(latitude: 0, longitude: 0), RoutePoint(latitude: 0.01, longitude: 0)]
        )
        let device = SimulatorDevice(udid: "A", name: "iPhone", runtime: "iOS 26", state: "Booted")

        variable.play(route: route, devices: [device])
        accelerate.play(route: route, devices: [device])
        XCTAssertEqual(variable.commandedSpeed * 3.6, 50, accuracy: 0.001)
        XCTAssertEqual(accelerate.commandedSpeed * 3.6, 10, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(1_150))

        XCTAssertEqual(variable.commandedSpeed * 3.6, 55, accuracy: 1)
        XCTAssertEqual(accelerate.commandedSpeed * 3.6, 15, accuracy: 1)
        let variableSetCalls = await variableService.setCalls
        let accelerateSetCalls = await accelerateService.setCalls
        let variableRouteCalls = await variableService.routeCalls
        let accelerateRouteCalls = await accelerateService.routeCalls
        XCTAssertGreaterThanOrEqual(variableSetCalls.count, 2)
        XCTAssertGreaterThanOrEqual(accelerateSetCalls.count, 2)
        XCTAssertTrue(variableRouteCalls.isEmpty)
        XCTAssertTrue(accelerateRouteCalls.isEmpty)

        await variable.stop()
        await accelerate.stop()
    }
}

private actor RecordingCommandRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
        let standardInput: Data?
    }

    private(set) var calls: [Call] = []
    private var results: [CommandResult]

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: String, arguments: [String], standardInput: Data?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, standardInput: standardInput))
        guard !results.isEmpty else { throw TestError.noResult }
        return results.removeFirst()
    }

    enum TestError: Error { case noResult }
}

private actor MockSimulatorService: SimulatorServicing {
    struct RouteCall: Sendable {
        let deviceID: String
        let speed: Double
        let pointCount: Int
    }

    private var devices: [SimulatorDevice]
    private let failingDeviceIDs: Set<String>
    private(set) var setCalls: [String] = []
    private(set) var routeCalls: [RouteCall] = []
    private(set) var clearCalls: [String] = []

    init(devices: [SimulatorDevice], failingDeviceIDs: Set<String> = []) {
        self.devices = devices
        self.failingDeviceIDs = failingDeviceIDs
    }

    func setDevices(_ devices: [SimulatorDevice]) {
        self.devices = devices
    }

    func bootedDevices() async throws -> [SimulatorDevice] { devices }

    func setLocation(latitude: Double, longitude: Double, deviceID: String) async throws {
        setCalls.append(deviceID)
        if failingDeviceIDs.contains(deviceID) { throw MockError.failed }
    }

    func clearLocation(deviceID: String) async throws {
        clearCalls.append(deviceID)
    }

    func startRoute(points: [RoutePoint], speed: Double, deviceID: String) async throws {
        routeCalls.append(RouteCall(deviceID: deviceID, speed: speed, pointCount: points.count))
        if failingDeviceIDs.contains(deviceID) { throw MockError.failed }
    }

    enum MockError: LocalizedError {
        case failed
        var errorDescription: String? { "Mock simctl failure" }
    }
}
