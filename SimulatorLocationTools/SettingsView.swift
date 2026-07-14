import AppKit
import Sparkle
import SwiftUI

enum AppWindow {
    static let about = "about"
}

enum AppAppearance: String, CaseIterable, Identifiable {
    static let storageKey = "appAppearance"

    case automatic
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var storedAppearance = AppAppearance.automatic.rawValue
    @Environment(\.openWindow) private var openWindow

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: storedAppearance) ?? .automatic },
            set: { storedAppearance = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Text("Auto follows your Mac's current appearance.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulator Location Tools")
                        Text(AppInformation().versionDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("About…") {
                        openWindow(id: AppWindow.about)
                    }
                }

                LabeledContent("GitHub") {
                    Link("adek/SimulatorLocationTools", destination: AppLinks.github)
                }

                LabeledContent("X") {
                    Link("@adekk", destination: AppLinks.x)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 300)
        .navigationTitle("Settings")
    }
}

struct AppInformation: Equatable {
    let name: String
    let version: String
    let build: String

    init(bundle: Bundle = .main) {
        name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Simulator Location Tools"
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var versionDescription: String {
        "Version \(version) (\(build))"
    }
}

enum AppLinks {
    static let github = URL(string: "https://github.com/adek/SimulatorLocationTools")!
    static let x = URL(string: "https://x.com/adekk")!
}

struct AboutView: View {
    @State private var showingLicense = false
    private let app = AppInformation()

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(app.name)
                    .font(.title2.weight(.semibold))
                Text(app.versionDescription)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Create, preview, and play simulated locations and routes on booted Apple platform Simulators.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Author")
                        .foregroundStyle(.secondary)
                    Text("Adrian Kajda")
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("License")
                        .foregroundStyle(.secondary)
                    Button("MIT License") {
                        showingLicense = true
                    }
                    .buttonStyle(.link)
                }
                GridRow {
                    Text("GitHub")
                        .foregroundStyle(.secondary)
                    Link("adek/SimulatorLocationTools", destination: AppLinks.github)
                }
                GridRow {
                    Text("X")
                        .foregroundStyle(.secondary)
                    Link("@adekk", destination: AppLinks.x)
                }
            }

            Text("Copyright © 2026 Adrian Kajda")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(width: 430)
        .sheet(isPresented: $showingLicense) {
            LicenseView()
        }
    }
}

private struct LicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The license text could not be loaded."
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MIT License")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                Text(licenseText)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 640, height: 460)
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let updaterController: SPUStandardUpdaterController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Simulator Location Tools") {
                openWindow(id: AppWindow.about)
            }
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updaterController.checkForUpdates(nil)
            }
        }
    }
}
