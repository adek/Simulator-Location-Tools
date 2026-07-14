import SwiftData
import SwiftUI
import Sparkle

@main
struct SimulatorLocationToolsApp: App {
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = AppAppearance.automatic.rawValue
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    private var preferredColorScheme: ColorScheme? {
        AppAppearance(rawValue: storedAppearance)?.colorScheme
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(preferredColorScheme)
        }
        .modelContainer(for: [SavedLocation.self, SavedRoute.self, FavoriteCountry.self])
        .defaultSize(width: 1_180, height: 720)
        .windowResizability(.contentMinSize)
        // Use the regular unified toolbar so controls have the room and visual
        // weight of a modern native macOS app while remaining in one titlebar.
        .windowToolbarStyle(.unified)
        .commands {
            AppCommands(updaterController: updaterController)
        }

        Settings {
            SettingsView()
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 500, height: 300)

        Window("About Simulator Location Tools", id: AppWindow.about) {
            AboutView()
                .preferredColorScheme(preferredColorScheme)
        }
        .windowResizability(.contentSize)
    }
}
