import AppKit
import MapKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @AppStorage(LibrarySelectionStorage.countryCodeKey) private var lastCountryCode = ""
    @AppStorage(LibrarySelectionStorage.locationIDKey) private var lastLocationID = ""
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \SavedLocation.name) private var savedLocations: [SavedLocation]
    @Query(sort: \SavedRoute.name) private var savedRoutes: [SavedRoute]
    @Query(sort: \FavoriteCountry.countryCode) private var favoriteCountries: [FavoriteCountry]
    @State private var model = AppModel()
    @State private var playback = RoutePlaybackModel()
    @State private var editor: EditorRequest?
    @State private var selectedRouteID: UUID?
    @State private var showRouteBuilder = false
    @State private var showGPXImporter = false
    @State private var exportDocument: GPXFileDocument?
    @State private var showGPXExporter = false
    @State private var exportFilename = "Route"
    @State private var routeToRename: SavedRoute?
    @State private var routeRenameText = ""
    @State private var librarySearchText = ""
    @State private var showAddActions = false
    @State private var restoredStartupSelection = false

    var body: some View {
        NavigationSplitView {
            countrySidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } content: {
            locationBrowser
                .navigationSplitViewColumnWidth(min: 380, ideal: 600)
                .layoutPriority(1)
        } detail: {
            simulatorPanel
                .navigationSplitViewColumnWidth(min: 320, ideal: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .containerBackground(opaqueSidebarBackground, for: .window)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack {
                    Button {
                        showAddActions.toggle()
                    } label: {
                        ToolbarIconLabel(systemName: "plus", accessibilityLabel: "Add")
                    }
                    .buttonStyle(.plain)
                    .disabled(model.catalog.countries.isEmpty)
                    .help("Add or import a location")
                    .popover(isPresented: $showAddActions, arrowEdge: .bottom) {
                        addActionsPopover
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    Button {
                        if let selectedLocation { edit(selectedLocation) }
                        else if let selectedRoute { rename(selectedRoute) }
                    } label: {
                        ToolbarIconLabel(systemName: "pencil", accessibilityLabel: "Rename or Edit")
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedRoute == nil && selectedLocation?.source != .saved)

                    Button {
                        if let selectedLocation { delete(selectedLocation) }
                        else if let selectedRoute { delete(selectedRoute) }
                    } label: {
                        ToolbarIconLabel(systemName: "trash", accessibilityLabel: "Delete")
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        (selectedRoute == nil && selectedLocation?.source != .saved)
                            || (playback.isPlaying && playback.activeRouteID == selectedRoute?.id)
                    )

                    Button {
                        openSettings()
                    } label: {
                        ToolbarIconLabel(systemName: "gearshape", accessibilityLabel: "Settings")
                    }
                    .buttonStyle(.plain)
                    .help("Settings")
                }
                .padding(.trailing, 6)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $librarySearchText)
                    .frame(width: 320, height: 36)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: $editor) { request in
            LocationEditor(
                request: request,
                countries: model.catalog.countries,
                onSave: saveLocation
            )
        }
        .sheet(isPresented: $showRouteBuilder) {
            RouteBuilderView(
                countries: model.catalog.countries,
                initialCountryCode: model.selectedCountryCode,
                onSave: saveRoute
            )
        }
        .sheet(item: $routeToRename) { route in
            RouteRenameEditor(name: routeRenameText) { newName in
                route.name = newName
                route.updatedAt = .now
                try modelContext.save()
            }
        }
        .fileImporter(isPresented: $showGPXImporter, allowedContentTypes: [.gpx, .xml]) { result in
            importGPX(result)
        }
        .fileExporter(
            isPresented: $showGPXExporter,
            document: exportDocument,
            contentType: .gpx,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                model.notice = AppModel.Notice(kind: .error, message: "Could not export GPX: \(error.localizedDescription)")
            }
            exportDocument = nil
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var firstRefresh = true
            while !Task.isCancelled {
                await model.refreshDevices(showError: firstRefresh)
                firstRefresh = false
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .task(id: librarySearchText) {
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            model.searchText = librarySearchText
        }
        .task {
            restoreStartupSelectionIfNeeded()
        }
        .onChange(of: model.selectedCountryCode, initial: true) { _, countryCode in
            guard playback.isPlaying == false, let countryCode else { return }
            if restoredStartupSelection {
                lastCountryCode = countryCode
            }
            if selectedLocation?.countryCode == countryCode || selectedRoute?.countryCode == countryCode {
                return
            }
            selectedRouteID = nil
            model.selectedLocationID = locations(in: countryCode).first?.id
        }
        .onChange(of: model.selectedLocationID) { _, locationID in
            guard restoredStartupSelection, let locationID else { return }
            lastLocationID = locationID
        }
        .onDisappear {
            if playback.isPlaying { Task { await playback.stop() } }
        }
    }

    private var addActionsPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                showAddActions = false
                editor = .new(countryCode: model.selectedCountryCode ?? model.catalog.countries.first?.code ?? "")
            } label: {
                Label("Add Location", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                showAddActions = false
                showRouteBuilder = true
            } label: {
                Label("Calculate Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button {
                showAddActions = false
                showGPXImporter = true
            } label: {
                Label("Import GPX", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 220)
    }

    private var locationBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedCountryCode.map { countryName(for: $0) } ?? "Locations")
                    .font(.title2.weight(.semibold))

                if let countryCode = model.selectedCountryCode {
                    Button {
                        toggleFavorite(countryCode)
                    } label: {
                        Image(systemName: isFavorite(countryCode) ? "star.fill" : "star")
                            .foregroundStyle(isFavorite(countryCode) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .disabled(playback.isPlaying)
                    .help(isFavorite(countryCode) ? "Remove (countryName(for: countryCode)) from favorites" : "Add (countryName(for: countryCode)) to favorites")
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Divider()

            VSplitView {
                locationList
                    .frame(minHeight: 180, idealHeight: 280)

                LocationMapView(
                    location: selectedLocation,
                    route: selectedRoute,
                    estimatedPosition: playback.activeRouteID == selectedRoute?.id ? playback.currentPoint : nil,
                    knownCountryCodes: model.catalog.knownCountryCodes,
                    onAdd: addMapResult
                )
                .frame(minHeight: 280, idealHeight: 400)
                .clipShape(Rectangle())
            }
        }
    }

    private var countrySidebar: some View {
        let sections = countrySections
        return List(selection: $model.selectedCountryCode) {
            if !sections.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(sections.favorites) { country in
                        countryRow(country, isFavorite: true)
                    }
                }
                .listSectionSeparator(.hidden)
            }

            Section("Countries") {
                ForEach(sections.regular) { country in
                    countryRow(country, isFavorite: false)
                }
            }
            .listSectionSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .disabled(playback.isPlaying)
    }

    private var opaqueSidebarBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.115, green: 0.125, blue: 0.135)
            : Color(red: 0.96, green: 0.96, blue: 0.97)
    }

    private func countryRow(_ country: CountrySummary, isFavorite: Bool) -> some View {
        HStack {
            if isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            Text(country.name)
            Spacer()
            Text(country.count, format: .number)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 3)
        .tag(Optional(country.code))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                toggleFavorite(country.code)
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "star.slash" : "star")
            }
        }
    }

    @ViewBuilder
    private var locationList: some View {
        if let countryCode = model.selectedCountryCode {
            List(selection: librarySelection) {
                let choices = locations(in: countryCode)
                let routes = routes(in: countryCode)
                if choices.isEmpty && routes.isEmpty {
                    ContentUnavailableView.search(text: model.searchText)
                } else {
                    ForEach(choices) { location in
                        LocationRow(location: location)
                            .tag(Optional(location.id))
                            .contextMenu {
                                if location.source == .saved {
                                    Button("Edit") { edit(location) }
                                    Button("Delete", role: .destructive) { delete(location) }
                                }
                            }
                    }
                    ForEach(routes) { route in
                        RouteRow(route: route, countryName: countryName(for: route.destinationCountryCode ?? route.countryCode))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .tag(Optional("route:\(route.id.uuidString)"))
                            .onTapGesture {
                                select(route)
                            }
                            .contextMenu {
                                Button("Rename") { rename(route) }
                                Button("Export GPX") { export(route) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(route) }
                                    .disabled(playback.isPlaying && playback.activeRouteID == route.id)
                            }
                    }
                }
            }
        } else {
            ContentUnavailableView("Choose a Country", systemImage: "globe", description: Text("Select a country to see its saved locations and capital preset."))
        }
    }

    private var simulatorPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Booted Simulators")
                        .font(.title2.weight(.semibold))
                    Text("simctl works with Simulator devices, not physical iPhones or iPads.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.activity.isWorking)
            }
            .padding()

            Divider()

            if model.devices.isEmpty {
                ContentUnavailableView(
                    "No Booted Simulators",
                    systemImage: "iphone.slash",
                    description: Text("Open an iOS Simulator in Xcode. It will appear here automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.devices) { device in
                    Toggle(isOn: deviceSelection(for: device.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .fontWeight(.medium)
                            Text("\(device.runtime)  •  \(device.udid)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 4)
                    .disabled(playback.isPlaying)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let selectedRoute { routePlaybackControls(selectedRoute) }
                else if let selectedLocation { locationControls(selectedLocation) }
                else {
                    Text("Select a location or route from the middle column.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    if let lastRefresh = model.lastRefresh {
                        Text("Device list checked \(lastRefresh, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 320, minHeight: 500)
    }

    @ViewBuilder
    private func locationControls(_ location: LocationChoice) -> some View {
        HStack {
            Image(systemName: "location.fill").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(location.name).fontWeight(.semibold)
                Text("\(location.latitude, format: .number.precision(.fractionLength(0...6))), \(location.longitude, format: .number.precision(.fractionLength(0...6)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        if let notice = model.notice { NoticeView(notice: notice) }
        HStack {
            Button {
                Task { await model.apply(location) }
            } label: {
                Label("Apply Location", systemImage: "location.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedDeviceIDs.isEmpty || model.activity.isWorking)

            Button {
                Task { await model.clearLocation() }
            } label: {
                Label("Clear", systemImage: "location.slash")
            }
            .disabled(model.selectedDeviceIDs.isEmpty || model.activity.isWorking)
            if model.activity.isWorking { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func routePlaybackControls(_ route: SavedRoute) -> some View {
        HStack {
            Image(systemName: route.transport.symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.name).fontWeight(.semibold)
                Text("\(route.startName) → \(route.endName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(formatDistance(route.distance)) • \(formatDuration(route.expectedTravelTime)) • \(route.points.count) points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Picker(
            "Speed behavior",
            selection: Binding(
                get: { playback.drivingProfile == .variable50To100 },
                set: { variable in
                    playback.changeProfile(to: variable ? .variable50To100 : .constant)
                }
            )
        ) {
            Text("Selected speed").tag(false)
            Text("Variable 50–100").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(playback.isPlaying)

        Toggle(
            "Smooth speed increase",
            isOn: Binding(
                get: { playback.drivingProfile == .accelerate },
                set: { smooth in playback.changeProfile(to: smooth ? .accelerate : .constant) }
            )
        )
        .disabled(playback.isPlaying || playback.drivingProfile == .variable50To100)

        if playback.drivingProfile == .variable50To100 {
            Text("Starts at 50 km/h, changes by about 5 km/h each second, and moves between 50 and 100 km/h.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if playback.drivingProfile == .accelerate {
            Text("Starts at 10 km/h and adds about 5 km/h each second until the selected target.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Picker(
            "Playback speed",
            selection: Binding(
                get: { playback.speedMultiplier },
                set: { speed in Task { await playback.changeSpeed(to: speed) } }
            )
        ) {
            Text("1× · 50").tag(1.0)
            Text("2× · 100").tag(2.0)
            Text("3× · 150").tag(3.0)
            Text("4× · 200").tag(4.0)
        }
        .pickerStyle(.segmented)
        .disabled(playback.drivingProfile == .variable50To100)
        .help("Playback speed in km/h")

        Toggle("Repeat playback", isOn: $playback.repeatPlayback)
            .disabled(playback.isPlaying)

        if playback.activeRouteID == route.id, playback.state != .idle {
            ProgressView(value: playback.progress)
            HStack {
                Text("\(formatDuration(playback.elapsed)) / \(formatDuration(playback.totalDuration))")
                Spacer()
                Text("\((playback.commandedSpeed * 3.6).formatted(.number.precision(.fractionLength(0...1)))) km/h")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let point = playback.currentPoint {
                HStack {
                    Label("Estimated position", systemImage: "location.fill")
                    Spacer()
                    Text("\(point.latitude, format: .number.precision(.fractionLength(0...5))), \(point.longitude, format: .number.precision(.fractionLength(0...5)))")
                        .monospacedDigit()
                }
                .font(.caption)
                if let elevation = point.elevation {
                    Text("GPX elevation: \(elevation.formatted(.number.precision(.fractionLength(0...1)))) m (display only)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let notice = playback.notice { NoticeView(notice: notice) }

        HStack {
            if playback.isPlaying {
                Button {
                    Task { await playback.stop() }
                } label: {
                    Label("Stop Route", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    playback.play(route: route, devices: selectedDevices)
                } label: {
                    Label("Play Route", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedDeviceIDs.isEmpty)
            }

            Button {
                Task {
                    if playback.activeRouteID != nil { await playback.stop() }
                    else { await model.clearLocation() }
                }
            } label: {
                Label("Clear", systemImage: "location.slash")
            }
            .disabled(model.selectedDeviceIDs.isEmpty && playback.activeRouteID == nil)

            Spacer()
            Button { export(route) } label: {
                Label("Export GPX", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var selectedDevices: [SimulatorDevice] {
        model.devices.filter { model.selectedDeviceIDs.contains($0.id) }
    }

    private func formatDistance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainingSeconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
            : String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private var selectedLocation: LocationChoice? {
        guard let id = model.selectedLocationID else { return nil }
        if id.hasPrefix("preset:"),
           let preset = model.catalog.presetByID[String(id.dropFirst("preset:".count))] {
            return choice(for: preset)
        }
        if id.hasPrefix("saved:"),
           let savedID = UUID(uuidString: String(id.dropFirst("saved:".count))),
           let saved = savedLocations.first(where: { $0.id == savedID }) {
            return choice(for: saved)
        }
        return nil
    }

    private func restoreStartupSelectionIfNeeded() {
        guard restoredStartupSelection == false else { return }

        let countryCode = StartupSelectionResolver.countryCode(
            lastCountryCode: lastCountryCode,
            favoriteCountryCodes: favoriteCountryCodes,
            countries: model.catalog.countries
        )
        model.selectedCountryCode = countryCode

        if let countryCode {
            let availableLocations = locations(in: countryCode)
            model.selectedLocationID = StartupSelectionResolver.locationID(
                lastLocationID: lastLocationID,
                availableLocationIDs: availableLocations.map(\.id)
            )
        } else {
            model.selectedLocationID = nil
        }

        restoredStartupSelection = true
    }

    private var selectedRoute: SavedRoute? {
        guard let selectedRouteID else { return nil }
        return savedRoutes.first { $0.id == selectedRouteID }
    }

    private func select(_ route: SavedRoute) {
        guard playback.isPlaying == false else { return }
        selectedRouteID = route.id
        model.selectedLocationID = nil
    }

    private var librarySelection: Binding<String?> {
        Binding(
            get: {
                if let selectedRouteID { return "route:\(selectedRouteID.uuidString)" }
                return model.selectedLocationID
            },
            set: { selection in
                guard playback.isPlaying == false else { return }
                if let selection,
                   selection.hasPrefix("route:"),
                   let id = UUID(uuidString: String(selection.dropFirst("route:".count))) {
                    selectedRouteID = id
                    model.selectedLocationID = nil
                } else {
                    selectedRouteID = nil
                    model.selectedLocationID = selection
                }
            }
        )
    }

    private var countrySections: (favorites: [CountrySummary], regular: [CountrySummary]) {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedByCountry = Dictionary(grouping: savedLocations, by: \SavedLocation.countryCode)
        let routesByCountry = Dictionary(grouping: savedRoutes, by: \SavedRoute.countryCode)
        let favoriteCodes = favoriteCountryCodes
        var favorites: [CountrySummary] = []
        var regular: [CountrySummary] = []

        for country in model.catalog.countries {
            let presets = model.catalog.presetsByCountry[country.code, default: []]
            let saved = savedByCountry[country.code, default: []]
            let routes = routesByCountry[country.code, default: []]
            let matches = query.isEmpty
                || country.name.localizedCaseInsensitiveContains(query)
                || presets.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || saved.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || routes.contains { routeMatchesSearch($0, query: query) }
            guard matches else { continue }

            let summary = CountrySummary(
                code: country.code,
                name: country.name,
                count: presets.count + saved.count + routes.count
            )
            if favoriteCodes.contains(country.code) {
                favorites.append(summary)
            } else {
                regular.append(summary)
            }
        }
        return (favorites, regular)
    }

    private var favoriteCountryCodes: Set<String> { Set(favoriteCountries.map(\.countryCode)) }

    private func isFavorite(_ countryCode: String?) -> Bool {
        countryCode.map(favoriteCountryCodes.contains) ?? false
    }

    private func toggleFavorite(_ countryCode: String) {
        do {
            if let favorite = favoriteCountries.first(where: { $0.countryCode == countryCode }) {
                modelContext.delete(favorite)
            } else {
                modelContext.insert(FavoriteCountry(countryCode: countryCode))
            }
            try modelContext.save()
        } catch {
            model.notice = AppModel.Notice(kind: .error, message: "Could not update favorites: \(error.localizedDescription)")
        }
    }

    private func locations(in countryCode: String) -> [LocationChoice] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = model.catalog.presetsByCountry[countryCode, default: []].map(choice(for:))
        let custom = savedLocations
            .filter { $0.countryCode == countryCode }
            .compactMap(choice(for:))
        return (presets + custom)
            .filter { $0.countryCode == countryCode && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.countryName.localizedCaseInsensitiveContains(query)) }
            .sorted { lhs, rhs in
                let lhsRank = lhs.presetKind?.sortOrder ?? 3
                let rhsRank = rhs.presetKind?.sortOrder ?? 3
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func routes(in countryCode: String) -> [SavedRoute] {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return savedRoutes.filter {
            $0.countryCode == countryCode && routeMatchesSearch($0, query: query)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func routeMatchesSearch(_ route: SavedRoute, query: String) -> Bool {
        query.isEmpty
            || route.name.localizedCaseInsensitiveContains(query)
            || route.startName.localizedCaseInsensitiveContains(query)
            || route.endName.localizedCaseInsensitiveContains(query)
            || countryName(for: route.countryCode).localizedCaseInsensitiveContains(query)
            || route.destinationCountryCode.map {
                countryName(for: $0).localizedCaseInsensitiveContains(query)
            } == true
    }

    private func countryName(for code: String) -> String {
        model.catalog.countryNameByCode[code] ?? code
    }

    private func choice(for preset: LocationPreset) -> LocationChoice {
        LocationChoice(
            id: "preset:\(preset.id)", name: preset.name, countryCode: preset.countryCode,
            countryName: preset.countryName, latitude: preset.latitude, longitude: preset.longitude,
            source: .preset, presetKind: preset.kind
        )
    }

    private func choice(for saved: SavedLocation) -> LocationChoice? {
        guard let countryName = model.catalog.countryNameByCode[saved.countryCode] else { return nil }
        return LocationChoice(
            id: "saved:\(saved.id.uuidString)", name: saved.name, countryCode: saved.countryCode,
            countryName: countryName, latitude: saved.latitude, longitude: saved.longitude,
            source: .saved, presetKind: nil
        )
    }

    private func deviceSelection(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedDeviceIDs.contains(id) },
            set: { selected in
                if selected { model.selectedDeviceIDs.insert(id) }
                else { model.selectedDeviceIDs.remove(id) }
            }
        )
    }

    private func edit(_ location: LocationChoice) {
        guard location.source == .saved,
              let saved = savedLocations.first(where: { "saved:\($0.id.uuidString)" == location.id }) else { return }
        editor = .edit(
            id: saved.id, name: saved.name, countryCode: saved.countryCode,
            latitude: saved.latitude, longitude: saved.longitude
        )
    }

    private func delete(_ location: LocationChoice) {
        guard location.source == .saved,
              let saved = savedLocations.first(where: { "saved:\($0.id.uuidString)" == location.id }) else { return }
        if model.selectedLocationID == location.id { model.selectedLocationID = nil }
        modelContext.delete(saved)
        try? modelContext.save()
    }

    private func addMapResult(_ result: MapSearchResult) -> Bool {
        guard let countryCode = result.countryCode?.uppercased(),
              model.catalog.knownCountryCodes.contains(countryCode) else {
            model.notice = AppModel.Notice(
                kind: .warning,
                message: "Apple Maps did not return a supported country for this location. Add it manually instead."
            )
            return false
        }

        if let existing = savedLocations.first(where: {
            $0.countryCode == countryCode
                && abs($0.latitude - result.latitude) < 0.000_01
                && abs($0.longitude - result.longitude) < 0.000_01
        }) {
            model.selectedCountryCode = countryCode
            model.selectedLocationID = "saved:\(existing.id.uuidString)"
            selectedRouteID = nil
            model.notice = AppModel.Notice(kind: .success, message: "\(existing.name) is already in your saved locations.")
            return true
        }

        let saved = SavedLocation(
            name: result.name,
            countryCode: countryCode,
            latitude: result.latitude,
            longitude: result.longitude
        )
        modelContext.insert(saved)
        do {
            try modelContext.save()
            model.selectedCountryCode = countryCode
            model.selectedLocationID = "saved:\(saved.id.uuidString)"
            selectedRouteID = nil
            model.notice = AppModel.Notice(kind: .success, message: "Added \(result.name) to \(countryName(for: countryCode)).")
            return true
        } catch {
            modelContext.delete(saved)
            model.notice = AppModel.Notice(kind: .error, message: "Could not save \(result.name): \(error.localizedDescription)")
            return false
        }
    }

    private func saveRoute(_ draft: RouteDraft) throws {
        guard model.catalog.knownCountryCodes.contains(draft.countryCode) else {
            throw RouteServiceError.missingCountry
        }
        let route = try SavedRoute(
            name: draft.name,
            countryCode: draft.countryCode,
            destinationCountryCode: draft.destinationCountryCode,
            startName: draft.startName,
            endName: draft.endName,
            source: draft.source,
            distance: draft.distance,
            expectedTravelTime: draft.expectedTravelTime,
            baseSpeed: draft.baseSpeed,
            points: draft.points
        )
        modelContext.insert(route)
        try modelContext.save()
        model.selectedCountryCode = route.countryCode
        model.selectedLocationID = nil
        selectedRouteID = route.id
        model.notice = AppModel.Notice(kind: .success, message: "Saved \(route.name) under \(countryName(for: route.countryCode)).")
    }

    private func importGPX(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result {
                model.notice = AppModel.Notice(kind: .error, message: "Could not open GPX: \(error.localizedDescription)")
            }
            return
        }
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let draft = try await AppleRouteService.importedDraft(
                    data: data,
                    fallbackName: url.deletingPathExtension().lastPathComponent,
                    fallbackCountryCode: model.selectedCountryCode,
                    knownCountryCodes: model.catalog.knownCountryCodes
                )
                try saveRoute(draft)
            } catch {
                model.notice = AppModel.Notice(kind: .error, message: "Could not import GPX: \(error.localizedDescription)")
            }
        }
    }

    private func export(_ route: SavedRoute) {
        exportDocument = GPXFileDocument(routeName: route.name, points: route.points)
        exportFilename = route.name.replacingOccurrences(of: "/", with: "-")
        showGPXExporter = true
    }

    private func rename(_ route: SavedRoute) {
        routeRenameText = route.name
        routeToRename = route
    }

    private func delete(_ route: SavedRoute) {
        guard playback.activeRouteID != route.id || playback.isPlaying == false else { return }
        if selectedRouteID == route.id { selectedRouteID = nil }
        modelContext.delete(route)
        do { try modelContext.save() }
        catch { model.notice = AppModel.Notice(kind: .error, message: "Could not delete route: \(error.localizedDescription)") }
    }

    private func saveLocation(_ draft: LocationDraft) throws {
        if let id = draft.id, let saved = savedLocations.first(where: { $0.id == id }) {
            saved.name = draft.name
            saved.countryCode = draft.countryCode
            saved.latitude = draft.latitude
            saved.longitude = draft.longitude
            saved.updatedAt = .now
            model.selectedLocationID = "saved:\(saved.id.uuidString)"
        } else {
            let saved = SavedLocation(name: draft.name, countryCode: draft.countryCode, latitude: draft.latitude, longitude: draft.longitude)
            modelContext.insert(saved)
            model.selectedLocationID = "saved:\(saved.id.uuidString)"
        }
        model.selectedCountryCode = draft.countryCode
        selectedRouteID = nil
        try modelContext.save()
    }
}

private struct LocationMapView: View {
    let location: LocationChoice?
    let route: SavedRoute?
    let estimatedPosition: RoutePoint?
    let knownCountryCodes: Set<String>
    let onAdd: (MapSearchResult) -> Bool
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var search = MapSearchModel()
    @State private var addedResultID: String?

    var body: some View {
        Map(position: $cameraPosition) {
            if let route, route.points.count >= 2 {
                MapPolyline(coordinates: route.points.map(\.coordinate))
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if let first = route.points.first {
                    Marker("Start", coordinate: first.coordinate).tint(.green)
                }
                if let last = route.points.last {
                    Marker("Destination", coordinate: last.coordinate).tint(.red)
                }
                if let estimatedPosition {
                    Annotation("Estimated position", coordinate: estimatedPosition.coordinate) {
                        Image(systemName: "car.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .blue)
                            .shadow(radius: 3)
                    }
                }
            }
            if let result = search.selectedResult {
                Marker(
                    result.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: result.latitude,
                        longitude: result.longitude
                    )
                )
                .tint(.orange)
            } else if route == nil, let location {
                Marker(
                    location.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                )
                .tint(.red)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapZoomStepper()
            MapScaleView()
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search Apple Maps", text: $search.query)
                        .textFieldStyle(.plain)
                        .onSubmit { search.search() }
                    if search.isSearching {
                        ProgressView().controlSize(.small)
                    } else if !search.query.isEmpty {
                        Button {
                            search.query = ""
                            search.results = []
                            search.errorMessage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                    Button("Search") { search.search() }
                        .disabled(search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.isSearching)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                if !search.results.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(search.results) { result in
                                Button {
                                    addedResultID = nil
                                    search.select(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.name).fontWeight(.medium)
                                        Text(result.address)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                if result.id != search.results.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(maxHeight: 210)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if let errorMessage = search.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                } else if location == nil && route == nil && search.selectedResult == nil {
                    Label("Select a saved location or route, or search for a city", systemImage: "map")
                        .font(.callout.weight(.medium))
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: 430)
        }
        .overlay(alignment: .bottomTrailing) {
            if let result = search.selectedResult {
                let canAdd = result.countryCode.map(knownCountryCodes.contains) == true
                Button {
                    if onAdd(result) { addedResultID = result.id }
                } label: {
                    Label(
                        addedResultID == result.id ? "Added" : "Add Location",
                        systemImage: addedResultID == result.id ? "checkmark" : "plus"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd || addedResultID == result.id)
                .help(canAdd ? "Save this result under its country" : "Apple Maps did not return a supported country for this result")
                .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let route {
                VStack(alignment: .leading, spacing: 2) {
                    Label(route.name, systemImage: route.transport.symbol)
                        .font(.callout.weight(.semibold))
                    Text("\(route.source.label) • \(route.points.count) points")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            }
        }
        .task(id: focusID) {
            if let result = search.selectedResult {
                cameraPosition = region(latitude: result.latitude, longitude: result.longitude)
            } else if let route {
                cameraPosition = region(points: route.points)
            } else if let location {
                cameraPosition = region(latitude: location.latitude, longitude: location.longitude)
            } else {
                cameraPosition = .automatic
            }
        }
        .accessibilityLabel(focusName.map { "Map showing \($0)" } ?? "Location preview map")
    }

    private var focusID: String? { search.selectedResult?.id ?? route.map { "route:\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970)" } ?? location?.id }
    private var focusName: String? { search.selectedResult?.name ?? route?.name ?? location?.name }

    private func region(latitude: Double, longitude: Double) -> MapCameraPosition {
        .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.18, longitudeDelta: 0.18)
        ))
    }

    private func region(points: [RoutePoint]) -> MapCameraPosition {
        guard let first = points.first else { return .automatic }
        let minLat = points.map(\.latitude).min() ?? first.latitude
        let maxLat = points.map(\.latitude).max() ?? first.latitude
        let minLon = points.map(\.longitude).min() ?? first.longitude
        let maxLon = points.map(\.longitude).max() ?? first.longitude
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(
                latitudeDelta: max((maxLat - minLat) * 1.35, 0.02),
                longitudeDelta: max((maxLon - minLon) * 1.35, 0.02)
            )
        ))
    }
}

private struct LocationRow: View {
    let location: LocationChoice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: location.presetKind?.symbol ?? "mappin.circle.fill")
                .foregroundStyle(location.source == .preset ? Color.secondary : Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(location.name).fontWeight(.medium)
                Text("\(location.latitude, format: .number.precision(.fractionLength(0...6))), \(location.longitude, format: .number.precision(.fractionLength(0...6)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RouteRow: View {
    let route: SavedRoute
    let countryName: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(route.name).fontWeight(.medium)
                    Text("ROUTE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Text("\(route.startName) → \(route.endName)")
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(distance)
                    Text("•")
                    Text(duration)
                    Text("•")
                    Text("\(route.points.count) pts")
                    if route.destinationCountryCode != nil, route.destinationCountryCode != route.countryCode {
                        Text("• \(countryName)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var distance: String {
        Measurement(value: route.distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var duration: String {
        let minutes = max(Int(route.expectedTravelTime / 60), 1)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

private struct RouteRenameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String) throws -> Void
    @State private var name: String
    @State private var errorMessage: String?

    init(name: String, onSave: @escaping (String) throws -> Void) {
        _name = State(initialValue: name)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Route").font(.title2.weight(.semibold))
            TextField("Route name", text: $name)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func save() {
        do {
            try onSave(name.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = "Could not rename route: \(error.localizedDescription)"
        }
    }
}

private struct NoticeView: View {
    let notice: AppModel.Notice

    private var color: Color {
        switch notice.kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }

    var body: some View {
        Label {
            Text(notice.message).textSelection(.enabled)
        } icon: {
            Image(systemName: notice.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ToolbarIconLabel: View {
    let systemName: String
    let accessibilityLabel: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 38, height: 38)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
            }
            .contentShape(Circle())
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct ToolbarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search locations", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1)
        }
    }
}

private enum EditorRequest: Identifiable {
    case new(countryCode: String)
    case edit(id: UUID, name: String, countryCode: String, latitude: Double, longitude: Double)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id, _, _, _, _): id.uuidString
        }
    }
}

private struct LocationDraft {
    let id: UUID?
    let name: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
}

private struct LocationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest
    let countries: [(code: String, name: String)]
    let onSave: (LocationDraft) throws -> Void

    @State private var name: String
    @State private var countryCode: String
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var errorMessage: String?

    init(request: EditorRequest, countries: [(code: String, name: String)], onSave: @escaping (LocationDraft) throws -> Void) {
        self.request = request
        self.countries = countries
        self.onSave = onSave
        switch request {
        case .new(let countryCode):
            _name = State(initialValue: "")
            _countryCode = State(initialValue: countryCode)
            _latitudeText = State(initialValue: "")
            _longitudeText = State(initialValue: "")
        case .edit(_, let name, let countryCode, let latitude, let longitude):
            _name = State(initialValue: name)
            _countryCode = State(initialValue: countryCode)
            _latitudeText = State(initialValue: CoordinateParser.commandString(latitude))
            _longitudeText = State(initialValue: CoordinateParser.commandString(longitude))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "Edit Location" : "Add Location")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name or city", text: $name)
                Picker("Country", selection: $countryCode) {
                    ForEach(countries, id: \.code) { country in
                        Text(country.name).tag(country.code)
                    }
                }
                TextField("Latitude", text: $latitudeText, prompt: Text("50.0614"))
                TextField("Longitude", text: $longitudeText, prompt: Text("19.9383"))
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var isEditing: Bool {
        if case .edit = request { true } else { false }
    }

    private var editID: UUID? {
        if case .edit(let id, _, _, _, _) = request { id } else { nil }
    }

    private func save() {
        let latitude = CoordinateParser.parse(latitudeText)
        let longitude = CoordinateParser.parse(longitudeText)
        if let error = LocationValidation.validate(
            name: name, countryCode: countryCode, latitude: latitude, longitude: longitude,
            knownCountryCodes: Set(countries.map(\.code))
        ) {
            errorMessage = error
            return
        }
        guard let latitude, let longitude else { return }
        do {
            try onSave(LocationDraft(
                id: editID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                countryCode: countryCode, latitude: latitude, longitude: longitude
            ))
            dismiss()
        } catch {
            errorMessage = "Could not save the location: \(error.localizedDescription)"
        }
    }
}
