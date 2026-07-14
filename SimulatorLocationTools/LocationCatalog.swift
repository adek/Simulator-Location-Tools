import Foundation

struct LocationCatalog: Sendable {
    let presets: [LocationPreset]
    let countries: [(code: String, name: String)]
    let presetsByCountry: [String: [LocationPreset]]
    let presetByID: [String: LocationPreset]
    let countryNameByCode: [String: String]
    let knownCountryCodes: Set<String>

    init(bundle: Bundle = .main) throws {
        guard let capitalsURL = bundle.url(forResource: "capitals", withExtension: "json"),
              let citiesURL = bundle.url(forResource: "cities", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        try self.init(
            data: Data(contentsOf: capitalsURL),
            supplementalData: Data(contentsOf: citiesURL)
        )
    }

    init(data: Data, supplementalData: Data? = nil) throws {
        do {
            let decoder = JSONDecoder()
            let capitals = try decoder.decode([LocationPreset].self, from: data)
            let cities = try supplementalData.map { try decoder.decode([LocationPreset].self, from: $0) } ?? []
            let sortedPresets = (capitals + cities).sorted {
                let countryComparison = $0.countryName.localizedStandardCompare($1.countryName)
                if countryComparison != .orderedSame { return countryComparison == .orderedAscending }
                if $0.kind.sortOrder != $1.kind.sortOrder { return $0.kind.sortOrder < $1.kind.sortOrder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            let groupedPresets = Dictionary(grouping: sortedPresets, by: \LocationPreset.countryCode)
            let namesByCode = groupedPresets.compactMapValues { $0.first?.countryName }

            presets = sortedPresets
            presetsByCountry = groupedPresets
            presetByID = Dictionary(sortedPresets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            countryNameByCode = namesByCode
            knownCountryCodes = Set(namesByCode.keys)
            countries = namesByCode
                .map { (code: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw CatalogError.invalidResource
        }
    }

    enum CatalogError: LocalizedError {
        case missingResource, invalidResource

        var errorDescription: String? {
            switch self {
            case .missingResource: "The bundled location catalog is missing."
            case .invalidResource: "The bundled location catalog could not be read."
            }
        }
    }
}
