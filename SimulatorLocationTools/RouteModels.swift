import CoreLocation
import Foundation
import SwiftData

struct RoutePoint: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
    let elevation: Double?
    let timestamp: Date?

    init(latitude: Double, longitude: Double, elevation: Double? = nil, timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
        self.timestamp = timestamp
    }

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum RouteSource: String, Codable, CaseIterable, Sendable {
    case calculated
    case gpx

    var label: String { self == .calculated ? "Apple Maps" : "GPX" }
}

enum RouteTransport: String, Codable, CaseIterable, Sendable {
    case automobile

    var label: String { "Driving" }
    var symbol: String { "car.fill" }
}

@Model
final class SavedRoute {
    @Attribute(.unique) var id: UUID
    var name: String
    var countryCode: String
    var destinationCountryCode: String?
    var startName: String
    var endName: String
    var sourceRawValue: String
    var transportRawValue: String
    var distance: Double
    var expectedTravelTime: Double
    var baseSpeed: Double
    @Attribute(.externalStorage) var encodedPoints: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        countryCode: String,
        destinationCountryCode: String?,
        startName: String,
        endName: String,
        source: RouteSource,
        transport: RouteTransport = .automobile,
        distance: Double,
        expectedTravelTime: Double,
        baseSpeed: Double,
        points: [RoutePoint],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws {
        self.id = id
        self.name = name
        self.countryCode = countryCode
        self.destinationCountryCode = destinationCountryCode
        self.startName = startName
        self.endName = endName
        self.sourceRawValue = source.rawValue
        self.transportRawValue = transport.rawValue
        self.distance = distance
        self.expectedTravelTime = expectedTravelTime
        self.baseSpeed = baseSpeed
        self.encodedPoints = try JSONEncoder().encode(points)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var source: RouteSource { RouteSource(rawValue: sourceRawValue) ?? .gpx }
    var transport: RouteTransport { RouteTransport(rawValue: transportRawValue) ?? .automobile }
    var points: [RoutePoint] { (try? JSONDecoder().decode([RoutePoint].self, from: encodedPoints)) ?? [] }
}

struct RouteDraft: Sendable {
    let name: String
    let countryCode: String
    let destinationCountryCode: String?
    let startName: String
    let endName: String
    let source: RouteSource
    let distance: Double
    let expectedTravelTime: Double
    let baseSpeed: Double
    let points: [RoutePoint]
}

enum RouteMetrics {
    static let fallbackDrivingSpeed = 13.888_888_9 // 50 km/h

    static func distance(of points: [RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + pair.0.location.distance(from: pair.1.location)
        }
    }

    static func timing(for points: [RoutePoint], distance: Double) -> (duration: Double, speed: Double) {
        if let first = points.first?.timestamp,
           let last = points.last?.timestamp,
           last > first {
            let duration = last.timeIntervalSince(first)
            return (duration, max(distance / duration, 0.1))
        }
        let duration = distance / fallbackDrivingSpeed
        return (duration, fallbackDrivingSpeed)
    }
}
