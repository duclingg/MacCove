//
//  UpdatesSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

/// This version, checking GitHub for a newer one, and the latest release
/// notes. `UpdateChecker` does the checking.
struct UpdatesSettingsView: View {
    // MARK: States
    @Environment(UpdateChecker.self) private var updates
    @AppStorage(UpdateChecker.automaticKey) private var checksAutomatically = true
    @AppStorage(UpdateChecker.betaKey) private var includesBetas = false

    private let isHomebrew = UpdateChecker.isInstalledWithHomebrew

    // MARK: View
    var body: some View {
        Form {
            Section {
                versionRow
                Toggle(isOn: $checksAutomatically) {
                    Text("Check for updates automatically")
                    Text("Once a day. Asks before downloading.")
                }
                .disabled(isHomebrew)
                Toggle(isOn: $includesBetas) {
                    Text("Include beta releases")
                    Text("New activities early. They may be rough.")
                }
                .disabled(isHomebrew)
            } footer: {
                Text(isHomebrew
                    ? "MacCove was installed with Homebrew, so brew upgrade handles its updates and these are turned off."
                    : "Releases come from github.com/\(UpdateChecker.repository). If you installed with Homebrew, brew upgrade handles updates and these are turned off.")
            }

            Section("Release notes") {
                if updates.releases.isEmpty {
                    Text(releaseNotesPlaceholder)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(updates.releases) { release in
                        releaseRow(release)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .settingsSwitch()
        .task {
            // The notes, and whether anything's new, when the pane opens
            // without having been checked yet.
            if updates.status == .idle, !isHomebrew {
                await updates.check()
            }
        }
        .onChange(of: includesBetas) {
            Task { await updates.check() }
        }
    }

    // MARK: View Components
    private var versionRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(versionTitle)
                HStack(spacing: 6) {
                    if updates.status == .checking {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(statusText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if case let .available(release) = updates.status {
                Button("Download") {
                    updates.download(release)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Check Now") {
                Task { await updates.check() }
            }
            .disabled(updates.status == .checking || isHomebrew)
        }
    }

    private func releaseRow(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(releaseTitle(release))
                let summary = UpdateChecker.summary(of: release.notes, lines: 1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button("View") {
                NSWorkspace.shared.open(release.pageURL)
            }
        }
    }

    // MARK: Text
    /// "MacCove 1.0 (12)".
    private var versionTitle: String {
        let build = UpdateChecker.currentBuild
        return "MacCove \(UpdateChecker.currentVersion)" + (build.isEmpty ? "" : " (\(build))")
    }

    private var statusText: String {
        switch updates.status {
        case .checking:
            return "Checking for updates"
        case let .available(release):
            return "MacCove \(release.version) is available" + (release.isPrerelease ? " as a beta" : "")
        case let .failed(reason):
            return "Couldn’t check. \(reason)"
        case .upToDate, .idle:
            guard let lastChecked = updates.lastChecked else {
                return isHomebrew ? "Updated with Homebrew" : "Not checked yet"
            }
            let upToDate = updates.status == .upToDate ? " · you’re up to date" : ""
            return "Checked \(Self.describe(lastChecked))\(upToDate)"
        }
    }

    /// "today at 9:41 AM", "yesterday at 9:41 AM", or "Nov 2 at 9:41 AM".
    private static func describe(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "today at \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "yesterday at \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)"
    }

    /// "1.1 · November 2", with Beta for a pre-release.
    private func releaseTitle(_ release: UpdateChecker.Release) -> String {
        let date = release.publishedAt == .distantPast ? nil : release.publishedAt.formatted(.dateTime.month(.wide).day())
        let beta = release.isPrerelease ? " Beta" : ""
        return [release.version + beta, date].compactMap { $0 }.joined(separator: " · ")
    }

    private var releaseNotesPlaceholder: String {
        switch updates.status {
        case .checking: "Looking for release notes"
        case .failed: "Release notes show here once MacCove can reach GitHub."
        default: "No releases on GitHub yet."
        }
    }
}

#if DEBUG
#Preview {
    UpdatesSettingsView()
        .environment(UpdateChecker())
}
#endif
