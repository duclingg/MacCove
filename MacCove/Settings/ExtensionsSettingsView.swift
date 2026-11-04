//
//  ExtensionsSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import SwiftUI

/// What's installed from the extension gallery, and how extensions update.
///
/// There's no gallery or extension runtime yet: Browse Gallery does nothing,
/// nothing can be installed, so Installed shows its empty state, and the
/// two settings are kept for when there is.
struct ExtensionsSettingsView: View {
    // MARK: AppStorage
    @AppStorage(InstalledExtension.autoUpdateKey) private var installsUpdatesAutomatically = true
    @AppStorage(InstalledExtension.folderExtensionsKey) private var allowsFolderExtensions = false
    @AppStorage(InstalledExtension.disabledKey) private var disabledIDs = ""

    /// Nothing can be installed yet.
    var installed: [InstalledExtension] = []

    // MARK: View
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Browse Gallery") {
                        // The gallery isn't built yet.
                    }
                    .buttonStyle(.borderedProminent)
                } label: {
                    Text("Find more in the gallery")
                    Text("Free extensions made by the community, each one reviewed")
                }
            }

            Section("Installed") {
                if installed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No extensions yet")
                        Text("What you install from the gallery shows here, to turn on and off.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(installed) { item in
                        extensionRow(item)
                    }
                }
            }

            Section {
                Toggle(isOn: $installsUpdatesAutomatically) {
                    Text("Install updates automatically")
                    Text("Only when an update asks for no new access. Otherwise you’re asked first.")
                }
                Toggle(isOn: $allowsFolderExtensions) {
                    Text("Allow extensions loaded from a folder")
                    Text("For making your own. These haven’t been reviewed.")
                }
            } footer: {
                Text("Each extension runs in its own sandbox and only reaches what it listed when you installed it. MacCove stops one that uses too much CPU or memory.")
            }
        }
        .formStyle(.grouped)
        .settingsSwitch()
    }

    // MARK: View Components
    private func extensionRow(_ item: InstalledExtension) -> some View {
        Toggle(isOn: Binding(
            get: { !disabled.contains(item.id) },
            set: { setEnabled(item, $0) }
        )) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(item.color.gradient)
                    .frame(width: 25, height: 25)
                    .overlay {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Turning off
    /// Turned-off extensions, by ID, kept as one line so AppStorage can
    /// hold them.
    private var disabled: Set<String> {
        Set(disabledIDs.split(separator: "\n").map(String.init))
    }

    private func setEnabled(_ item: InstalledExtension, _ enabled: Bool) {
        var ids = disabled
        if enabled {
            ids.remove(item.id)
        } else {
            ids.insert(item.id)
        }
        disabledIDs = ids.sorted().joined(separator: "\n")
    }
}

/// An extension installed from the gallery, as the pane lists it.
struct InstalledExtension: Identifiable {
    enum UpdateState {
        case upToDate
        case available
        /// The update lists access this version doesn't have, so it waits
        /// for you to agree.
        case wantsNewAccess
    }

    static let autoUpdateKey = "ExtensionsInstallUpdatesAutomatically"
    static let folderExtensionsKey = "ExtensionsAllowFromFolder"
    static let disabledKey = "ExtensionsDisabled"

    let id: String
    let name: String
    /// Without the "@".
    let author: String
    let version: String
    let symbol: String
    let color: Color
    /// Nothing beyond what every extension gets.
    var needsNoAccess = false
    var update: UpdateState = .upToDate

    /// "@kenji · 1.0.3 · no access needed".
    var detail: String {
        var parts = ["@\(author)", version]
        switch update {
        case .available: parts.append("update available")
        case .wantsNewAccess: parts.append("update wants new access")
        case .upToDate: if needsNoAccess { parts.append("no access needed") }
        }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview("Empty") {
    ExtensionsSettingsView()
}

/// The design's extensions, to see the list filled in.
#Preview("Installed") {
    ExtensionsSettingsView(installed: [
        InstalledExtension(id: "pomodoro", name: "Pomodoro", author: "kenji", version: "1.0.3", symbol: "timer", color: .red, needsNoAccess: true),
        InstalledExtension(id: "lyrics", name: "Lyrics", author: "lyra", version: "2.0.4", symbol: "quote.opening", color: .pink, update: .available),
        InstalledExtension(id: "home-assistant", name: "Home Assistant", author: "samhomelab", version: "2.4.1", symbol: "house.fill", color: .cyan, update: .wantsNewAccess),
        InstalledExtension(id: "vercel-deploys", name: "Vercel Deploys", author: "tomas", version: "3.0.0", symbol: "triangle.fill", color: .black),
    ])
}
#endif
