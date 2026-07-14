# Simulator Location Tools

**Set a place, build a route, and make your iOS Simulators move.**

Simulator Location Tools is a native macOS app for developers who need reliable, repeatable location scenarios while building and testing iOS apps. Instead of repeatedly opening Simulator's location menu or typing coordinates into a terminal, choose a real place from a country-organized library, search Apple Maps, or play a driving route across one or more booted simulators.

It is particularly useful for testing location-aware experiences such as delivery tracking, travel apps, map views, nearby search, geofencing, and location-driven onboarding.

> Screenshots will be added in [`docs/screenshots`](docs/screenshots/).

## What it does

- **Set a location quickly** — choose a bundled capital or city, save your own places, preview them on a map, and apply the location to one or many booted iOS Simulators.
- **Browse by country** — start with a built-in offline catalog covering **196 countries**, including national capitals, U.S. state capitals, and **42 additional cities**. Pin frequently used countries to Favorites.
- **Search real places** — use Apple Maps to find an address or point of interest, preview it, and save it in the appropriate country group.
- **Test movement, not just a pin** — calculate an Apple Maps driving route or import a GPX file, then play it on selected simulators.
- **Control route playback** — use constant, accelerating, or variable-speed profiles; change constant speed live; repeat a route; view progress and an estimated current position.
- **Import and export GPX** — import track points, route points, or waypoints, and export Xcode-compatible waypoint GPX files. Elevation and timestamps are retained when GPX data provides them.
- **Stay native** — the app is built with SwiftUI, MapKit, SwiftData, and the Xcode command-line tools already used by iOS developers.

## How it works

1. Launch one or more iOS Simulators.
2. Open Simulator Location Tools; booted devices appear automatically.
3. Select a country and place, search Apple Maps, or add a custom coordinate.
4. Select the simulators you want to control and choose **Apply Location**.
5. For movement scenarios, create or import a route and choose **Play Route**.

The app targets each device by its UDID, so the same location or route can be applied to several simulators at once.

## Routes and GPX

Create a driving route by searching for a start and destination. Simulator Location Tools asks Apple Maps for the route, displays its polyline, and stores the route with its distance, estimated duration, endpoints, and point count.

You can also import GPX files containing `<trkpt>`, `<rtept>`, or `<wpt>` points. Imported routes are organized under their starting country; the app reverse-geocodes the endpoints when possible. GPX exports use Xcode-compatible waypoints.

Simulator location playback accepts latitude and longitude, but not elevation. The app preserves elevation for display and GPX export. Playback progress and the moving map marker are estimates because `simctl` does not provide live route telemetry.

## Requirements

- macOS 26 or later
- Xcode 26 or later, including iOS Simulator and command-line tools
- At least one booted iOS Simulator to apply a location or play a route

## Run from source

1. Clone this repository.
2. Open `SimulatorLocationTools.xcodeproj` in Xcode.
3. Select the **SimulatorLocationTools** scheme and the **My Mac** destination.
4. Build and run.

The project resolves [Sparkle](https://github.com/sparkle-project/Sparkle) through Swift Package Manager for app updates.

## Data and privacy

Simulator Location Tools does not collect analytics, tracking data, or usage information. The bundled catalog is based on [GeoNames](https://www.geonames.org/) data, licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The offline catalog lets you browse common testing locations without a separate location-data service. Apple Maps is used only when you choose to search or calculate a route.

## License

Created by [Adrian Kajda](https://kajda.com) and released under the [MIT License](LICENSE).
