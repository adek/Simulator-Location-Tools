import CoreLocation
import Foundation
import MapKit

struct CalculatedRoute: Sendable {
    let points: [RoutePoint]
    let distance: Double
    let expectedTravelTime: Double
}

struct GeocodedEndpoint: Sendable {
    let name: String
    let countryCode: String?
}

enum RouteServiceError: LocalizedError {
    case noRoute
    case insufficientPoints
    case missingCountry

    var errorDescription: String? {
        switch self {
        case .noRoute: "Apple Maps could not calculate a driving route between these locations."
        case .insufficientPoints: "The route contains fewer than two usable points."
        case .missingCountry: "The route's starting country could not be determined."
        }
    }
}

@MainActor
enum AppleRouteService {
    static func calculate(from start: MapSearchResult, to end: MapSearchResult) async throws -> CalculatedRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(
            location: CLLocation(latitude: start.latitude, longitude: start.longitude),
            address: nil
        )
        request.destination = MKMapItem(
            location: CLLocation(latitude: end.latitude, longitude: end.longitude),
            address: nil
        )
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteServiceError.noRoute }

        var coordinates = Array(repeating: kCLLocationCoordinate2DInvalid, count: route.polyline.pointCount)
        route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: route.polyline.pointCount))
        let points = coordinates
            .filter(CLLocationCoordinate2DIsValid)
            .map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        guard points.count >= 2 else { throw RouteServiceError.insufficientPoints }
        return CalculatedRoute(points: points, distance: route.distance, expectedTravelTime: route.expectedTravelTime)
    }

    static func reverseGeocode(_ point: RoutePoint) async -> GeocodedEndpoint? {
        guard let request = MKReverseGeocodingRequest(location: point.location) else { return nil }
        guard let item = try? await request.mapItems.first else { return nil }
        let representations = item.addressRepresentations
        let name = representations?.cityName
            ?? item.name
            ?? "\(CoordinateParser.commandString(point.latitude)), \(CoordinateParser.commandString(point.longitude))"
        return GeocodedEndpoint(name: name, countryCode: representations?.__regionCode)
    }

    static func importedDraft(
        data: Data,
        fallbackName: String,
        fallbackCountryCode: String?,
        knownCountryCodes: Set<String>
    ) async throws -> RouteDraft {
        let imported = try GPXParser.parse(data: data)
        guard let first = imported.points.first, let last = imported.points.last else {
            throw RouteServiceError.insufficientPoints
        }
        let start = await reverseGeocode(first)
        let end = await reverseGeocode(last)
        let detectedStart = start?.countryCode?.uppercased()
        let countryCode = detectedStart.flatMap { knownCountryCodes.contains($0) ? $0 : nil } ?? fallbackCountryCode
        guard let countryCode, knownCountryCodes.contains(countryCode) else {
            throw RouteServiceError.missingCountry
        }
        let distance = RouteMetrics.distance(of: imported.points)
        let timing = RouteMetrics.timing(for: imported.points, distance: distance)
        let startName = start?.name ?? "Start"
        let endName = end?.name ?? "End"
        let detectedDestination = end?.countryCode?.uppercased()
        let destinationCountryCode = detectedDestination.flatMap {
            knownCountryCodes.contains($0) ? $0 : nil
        }
        let suggestedName = imported.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = suggestedName?.isEmpty == false ? suggestedName! : (fallbackName.isEmpty ? "\(startName) → \(endName)" : fallbackName)
        return RouteDraft(
            name: name,
            countryCode: countryCode.uppercased(),
            destinationCountryCode: destinationCountryCode,
            startName: startName,
            endName: endName,
            source: .gpx,
            distance: distance,
            expectedTravelTime: timing.duration,
            baseSpeed: timing.speed,
            points: imported.points
        )
    }
}
