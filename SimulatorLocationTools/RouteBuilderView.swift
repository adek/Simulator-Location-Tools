import MapKit
import SwiftUI

struct RouteBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    let countries: [(code: String, name: String)]
    let initialCountryCode: String?
    let onSave: (RouteDraft) throws -> Void

    @State private var startSearch = MapSearchModel()
    @State private var endSearch = MapSearchModel()
    @State private var calculatedRoute: CalculatedRoute?
    @State private var routeName = ""
    @State private var countryCode = ""
    @State private var isCalculating = false
    @State private var errorMessage: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create Driving Route")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 16) {
                    EndpointSearchView(title: "Start", systemImage: "a.circle.fill", search: startSearch)
                    EndpointSearchView(title: "Destination", systemImage: "b.circle.fill", search: endSearch)

                    Button {
                        calculate()
                    } label: {
                        if isCalculating {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Calculate Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(startSearch.selectedResult == nil || endSearch.selectedResult == nil || isCalculating)

                    if let calculatedRoute {
                        Divider()
                        TextField("Route name", text: $routeName)
                        Picker("Starting country", selection: $countryCode) {
                            ForEach(countries, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        LabeledContent("Distance", value: Measurement(value: calculatedRoute.distance, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road)))
                        LabeledContent("Estimated time", value: Duration.seconds(calculatedRoute.expectedTravelTime).formatted(.time(pattern: .hourMinute)))
                        LabeledContent("Route points", value: calculatedRoute.points.count.formatted())
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        Button("Save Route") { save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(calculatedRoute == nil || routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || countryCode.isEmpty)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 390)

                Map(position: $cameraPosition) {
                    if let start = startSearch.selectedResult {
                        Marker("Start", coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
                            .tint(.green)
                    }
                    if let end = endSearch.selectedResult {
                        Marker("Destination", coordinate: CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude))
                            .tint(.red)
                    }
                    if let calculatedRoute {
                        MapPolyline(coordinates: calculatedRoute.points.map(\.coordinate))
                            .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapCompass(); MapZoomStepper(); MapScaleView() }
                .frame(minWidth: 430)
            }
        }
        .frame(width: 880, height: 650)
        .onAppear { countryCode = initialCountryCode ?? countries.first?.code ?? "" }
    }

    private func calculate() {
        guard let start = startSearch.selectedResult, let end = endSearch.selectedResult else { return }
        isCalculating = true
        errorMessage = nil
        calculatedRoute = nil
        Task {
            defer { isCalculating = false }
            do {
                let result = try await AppleRouteService.calculate(from: start, to: end)
                calculatedRoute = result
                routeName = "\(start.name) → \(end.name)"
                if let detected = start.countryCode?.uppercased(), countries.contains(where: { $0.code == detected }) {
                    countryCode = detected
                }
                cameraPosition = Self.region(for: result.points)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let route = calculatedRoute,
              let start = startSearch.selectedResult,
              let end = endSearch.selectedResult else { return }
        do {
            try onSave(RouteDraft(
                name: routeName.trimmingCharacters(in: .whitespacesAndNewlines),
                countryCode: countryCode,
                destinationCountryCode: end.countryCode?.uppercased(),
                startName: start.name,
                endName: end.name,
                source: .calculated,
                distance: route.distance,
                expectedTravelTime: route.expectedTravelTime,
                baseSpeed: max(route.distance / max(route.expectedTravelTime, 1), 0.1),
                points: route.points
            ))
            dismiss()
        } catch {
            errorMessage = "Could not save the route: \(error.localizedDescription)"
        }
    }

    private static func region(for points: [RoutePoint]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        let latitudes = points.map(\.latitude)
        let longitudes = points.map(\.longitude)
        let minLat = latitudes.min() ?? first.latitude
        let maxLat = latitudes.max() ?? first.latitude
        let minLon = longitudes.min() ?? first.longitude
        let maxLon = longitudes.max() ?? first.longitude
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.02),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.02)
            )
        ))
    }
}

private struct EndpointSearchView: View {
    let title: String
    let systemImage: String
    @Bindable var search: MapSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            HStack {
                TextField("Search Apple Maps", text: $search.query)
                    .onSubmit { search.search() }
                if search.isSearching { ProgressView().controlSize(.small) }
                Button("Search") { search.search() }
                    .disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.isSearching)
            }
            if let selected = search.selectedResult {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.name).fontWeight(.medium)
                    Text(selected.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if search.results.isEmpty == false {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(search.results) { result in
                            Button {
                                search.select(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.name).fontWeight(.medium)
                                    Text(result.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            if let error = search.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
