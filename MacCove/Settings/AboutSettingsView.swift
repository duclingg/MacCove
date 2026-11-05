//
//  AboutSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

/// MacCove's icon, version and licence, with links to its source and to
/// report a bug.
struct AboutSettingsView: View {
    private static let repositoryURL = URL(string: "https://github.com/\(UpdateChecker.repository)")!

    @Environment(NotchCommands.self) private var notch

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("MacCove")
                .font(.system(size: 20, weight: .bold))
                .padding(.top, 14)
            Text(versionText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("Free and open source under GPL-3.0. MacCove collects nothing about you.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 10)

            HStack(spacing: 8) {
                Button("Source Code") {
                    NSWorkspace.shared.open(Self.repositoryURL)
                }
                Button("Report a Bug") {
                    NSWorkspace.shared.open(Self.newIssueURL)
                }
                Button("Show Welcome Again") {
                    notch.showWelcome()
                }
            }
            .padding(.top, 18)

            Text("Made by Justin Hoang and contributors")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 28)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Version 1.0 (12)".
    private var versionText: String {
        let build = UpdateChecker.currentBuild
        return "Version \(UpdateChecker.currentVersion)" + (build.isEmpty ? "" : " (\(build))")
    }

    /// A new issue, with the versions it was found on filled in.
    private static var newIssueURL: URL {
        let build = UpdateChecker.currentBuild
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let body = """
            **What happened**


            **What you expected**


            MacCove \(UpdateChecker.currentVersion)\(build.isEmpty ? "" : " (\(build))"), \
            macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)
            """
        var components = URLComponents(url: repositoryURL.appending(path: "issues/new"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "body", value: body)]
        return components?.url ?? repositoryURL
    }
}

#if DEBUG
#Preview {
    AboutSettingsView()
        .environment(NotchCommands())
        .frame(width: 600, height: 500)
}
#endif
