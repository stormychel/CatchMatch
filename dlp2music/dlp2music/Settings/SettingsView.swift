//
//  SettingsView.swift
//  dlp2music
//
//  Created by Michel Storms on 10/05/2026.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    // Same keys and defaults as the destination chips in the main window (#85).
    @AppStorage("importToMusic") private var importMusicAudio: Bool = true
    @AppStorage("importToMusicVideo") private var importMusicVideo: Bool = true
    @AppStorage("importToTV") private var importToTV: Bool = false
    // Same key and default as UsageAnalytics.isEnabled (#157).
    @AppStorage("analytics.enabled") private var shareUsageCounts: Bool = true

    var body: some View {
        // One pane since the License tab went (#169), so no tab bar.
        generalTab
            .frame(width: 460, height: 470)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section("Defaults") {
                Toggle("Import songs to Apple Music", isOn: $importMusicAudio)
                Toggle("Import music videos to Apple Music", isOn: $importMusicVideo)
                Toggle("Import to Apple TV", isOn: $importToTV)
            }
            Section("Window & menu bar") {
                Toggle("Show in menu bar", isOn: $settings.menuBarEnabled)
                    .onChange(of: settings.menuBarEnabled) { _, newValue in
                        // Don't allow hiding the menu bar while the Dock icon is also
                        // hidden — otherwise the app has no visible entry point.
                        if !newValue && settings.dockIconHidden {
                            settings.dockIconHidden = false
                            settings.applyDockIconPolicy()
                        }
                    }
                Toggle("Hide Dock icon (menu-bar-only mode)", isOn: $settings.dockIconHidden)
                    .onChange(of: settings.dockIconHidden) { _, newValue in
                        // Enabling Hide-Dock-icon while the menu bar is off would also
                        // leave no entry point — re-enable the menu bar in that case.
                        if newValue && !settings.menuBarEnabled {
                            settings.menuBarEnabled = true
                        }
                        settings.applyDockIconPolicy()
                    }
                    .disabled(!settings.menuBarEnabled)
                    .help("When enabled, the app runs as a menu-bar-only utility. Disable to also keep a Dock icon and a main window.")
            }
            Section("Login") {
                Toggle("Launch at login", isOn: $settings.launchAtLoginEnabled)
                    .onChange(of: settings.launchAtLoginEnabled) { _, newValue in
                        let resulting = settings.setLaunchAtLogin(newValue)
                        if resulting != newValue {
                            // SMAppService refused; revert the toggle to the actual state.
                            settings.launchAtLoginEnabled = resulting
                        }
                    }
            }
            // Hidden in a build with nowhere to send to, where it would do nothing.
            if UsageAnalytics.shared.isConfigured {
                Section("Privacy") {
                    Toggle("Share anonymous usage counts", isOn: $shareUsageCounts)
                        .onChange(of: shareUsageCounts) { _, newValue in
                            // Through the setter, so turning it off forgets the
                            // install's identifier.
                            UsageAnalytics.shared.isEnabled = newValue
                        }
                    Text("Counts launches and imports, so I can see where people get stuck. Never your links, titles or files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Support") {
                // #169: free and open source; tips keep it going.
                Link(destination: Constants.buyMeACoffeeURL) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
                Text("\(Constants.appName) is free and open source. If it saves you time, a coffee keeps it going.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
}
