import MapKit
import Observation

struct MapSearchResult: Identifiable, Hashable, Sendable {
    var id: String { "\(name)|\(latitude)|\(longitude)" }
    let name: String
    let address: String
    let countryCode: String?
    let latitude: Double
    let longitude: Double
}

@MainActor
@Observable
final class MapSearchModel {
    var query = ""
    var results: [MapSearchResult] = []
    var selectedResult: MapSearchResult?
    var isSearching = false
    var errorMessage: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search() {
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            results = []
            errorMessage = nil
            return
        }

        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isSearching = false }
            do {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = searchText
                request.resultTypes = [.address, .pointOfInterest]
                let response = try await MKLocalSearch(request: request).start()
                try Task.checkCancellation()
                results = response.mapItems.prefix(10).map(Self.result(from:))
                if results.isEmpty {
                    errorMessage = "No places found. Try a city name with its country."
                }
            } catch is CancellationError {
                return
            } catch {
                results = []
                errorMessage = "Apple Maps search failed: \(error.localizedDescription)"
            }
        }
    }

    func select(_ result: MapSearchResult) {
        selectedResult = result
        results = []
        errorMessage = nil
    }

    private static func result(from item: MKMapItem) -> MapSearchResult {
        let representations = item.addressRepresentations
        let city = representations?.cityName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemName = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = city?.isEmpty == false ? city! : (itemName?.isEmpty == false ? itemName! : "Dropped Location")
        let address = representations?.fullAddress(includingRegion: true, singleLine: true)
            ?? item.address?.fullAddress
            ?? name
        let coordinate = item.location.coordinate
        return MapSearchResult(
            name: name,
            address: address,
            countryCode: representations?.__regionCode,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }
}
