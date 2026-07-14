import Foundation
import SwiftData

struct SimulatorDevice: Identifiable, Hashable, Sendable {
    var id: String { udid }
    let udid: String
    let name: String
    let runtime: String
    let state: String
}

struct LocationPreset: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case nationalCapital
        case stateCapital
        case city

        var symbol: String {
            switch self {
            case .nationalCapital, .stateCapital: "building.columns.fill"
            case .city: "building.2.fill"
            }
        }

        var sortOrder: Int {
            switch self {
            case .nationalCapital: 0
            case .stateCapital: 1
            case .city: 2
            }
        }
    }

    var id: String { countryCode + ":" + name }
    let countryCode: String
    let countryName: String
    let name: String
    let latitude: Double
    let longitude: Double
    let kind: Kind

    private enum CodingKeys: String, CodingKey {
        case countryCode, countryName, name, latitude, longitude, kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        countryCode = try values.decode(String.self, forKey: .countryCode)
        countryName = try values.decode(String.self, forKey: .countryName)
        name = try values.decode(String.self, forKey: .name)
        latitude = try values.decode(Double.self, forKey: .latitude)
        longitude = try values.decode(Double.self, forKey: .longitude)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .nationalCapital
    }
}

struct LocationChoice: Identifiable, Hashable {
    enum Source: Hashable { case preset, saved }

    let id: String
    let name: String
    let countryCode: String
    let countryName: String
    let latitude: Double
    let longitude: Double
    let source: Source
    let presetKind: LocationPreset.Kind?
}

@Model
final class SavedLocation {
    @Attribute(.unique) var id: UUID
    var name: String
    var countryCode: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        countryCode: String,
        latitude: Double,
        longitude: Double,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class FavoriteCountry {
    @Attribute(.unique) var countryCode: String
    var createdAt: Date

    init(countryCode: String, createdAt: Date = .now) {
        self.countryCode = countryCode
        self.createdAt = createdAt
    }
}

struct CountrySummary: Identifiable, Hashable {
    var id: String { code }
    let code: String
    let name: String
    let count: Int
}

enum LibrarySelectionStorage {
    static let countryCodeKey = "library.lastSelectedCountryCode"
    static let locationIDKey = "library.lastSelectedLocationID"
}

enum StartupSelectionResolver {
    static func countryCode(
        lastCountryCode: String,
        favoriteCountryCodes: Set<String>,
        countries: [(code: String, name: String)]
    ) -> String? {
        if countries.contains(where: { $0.code == lastCountryCode }) {
            return lastCountryCode
        }
        return countries.first(where: { favoriteCountryCodes.contains($0.code) })?.code
            ?? countries.first?.code
    }

    static func locationID(lastLocationID: String, availableLocationIDs: [String]) -> String? {
        if availableLocationIDs.contains(lastLocationID) {
            return lastLocationID
        }
        return availableLocationIDs.first
    }
}

enum CoordinateParser {
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = Double(trimmed) { return direct }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.number(from: trimmed)?.doubleValue
    }

    static func commandString(_ value: Double) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).precision(.fractionLength(0...8)).grouping(.never))
    }
}

enum LocationValidation {
    static func validate(name: String, countryCode: String, latitude: Double?, longitude: Double?, knownCountryCodes: Set<String>) -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a location name." }
        if !knownCountryCodes.contains(countryCode) { return "Choose a country." }
        guard let latitude else { return "Enter a valid latitude." }
        guard (-90...90).contains(latitude) else { return "Latitude must be between −90 and 90." }
        guard let longitude else { return "Enter a valid longitude." }
        guard (-180...180).contains(longitude) else { return "Longitude must be between −180 and 180." }
        return nil
    }
}
