//
//  DeveloperToolsSettingsView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import SwiftUI

struct DeveloperToolsSettingsView: View {
    // MARK: States
    @Environment(GitHubMonitor.self) private var github
    @AppStorage(TerminalHook.thresholdKey) private var terminalThreshold = TerminalHook.defaultThreshold
    @AppStorage(GitHubSetup.sourceKey) private var githubSource = ""

    @State private var installedTools: Set<AITool> = []
    @State private var toolsWithHooks: Set<AITool> = []
    @State private var isXcodeInstalled = false
    @State private var hasXcodeScripts = false
    @State private var hasTerminalHook = false

    // MARK: View
    var body: some View {
        Form {
            Section("Coding agents") {
                ForEach(AITool.allCases, id: \.self) { tool in
                    aiToolRow(tool)
                }
            }

            Section("Editors and terminal") {
                xcodeRow
                vsCodeRow
                terminalRow
                terminalThresholdRow
            }

            Section {
                gitHubRow
            } header: {
                Text("Accounts")
            } footer: {
                Text("Remove takes out only what Set Up added. A token you paste is kept in your login keychain.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            for tool in AITool.allCases {
                refresh(tool)
            }
            refreshXcode()
            hasTerminalHook = TerminalHook.isInstalled()
        }
    }

    private func refresh(_ tool: AITool) {
        if tool.setup.isInstalled() {
            installedTools.insert(tool)
        } else {
            installedTools.remove(tool)
        }
        if tool.setup.hooksSetup() {
            toolsWithHooks.insert(tool)
        } else {
            toolsWithHooks.remove(tool)
        }
    }

    private func refreshXcode() {
        isXcodeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") != nil
        hasXcodeScripts = XcodeBehaviorScripts.isSetUp
    }

    // MARK: View Components
    private func toolLabel<Icon: View>(_ name: String, detail: String, @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 10) {
            icon()
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tool's icon, name and detail, then "On" once it's set up, then
    /// its buttons.
    private func toolRow<Actions: View>(
        _ name: String,
        icon: ToolIcon,
        detail: String,
        isOn: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 12) {
            toolLabel(name, detail: detail) {
                icon
            }
            Spacer(minLength: 0)
            if isOn {
                onStatus
            }
            actions()
        }
    }

    private var onStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 8, height: 8)
            Text("On")
        }
        .foregroundStyle(.green)
    }

    // MARK: Coding agents
    private func aiToolDetail(_ tool: AITool) -> String {
        if toolsWithHooks.contains(tool) {
            "Hooks in \(tool.path)"
        } else if installedTools.contains(tool) {
            "Adds hooks to \(tool.path)"
        } else {
            "Install \(tool.name) to use this"
        }
    }

    private func aiToolRow(_ tool: AITool) -> some View {
        let hasHooks = toolsWithHooks.contains(tool)
        return toolRow(tool.name, icon: tool.icon, detail: aiToolDetail(tool), isOn: hasHooks) {
            // Remove still works once the tool is gone, so its hooks
            // don't stay behind.
            Button(hasHooks ? "Remove" : "Set Up") {
                if hasHooks {
                    tool.setup.remove()
                } else {
                    tool.setup.setup()
                }
                refresh(tool)
                if !hasHooks, toolsWithHooks.contains(tool) {
                    Task { await tool.askForPermissions() }
                }
            }
            .disabled(!hasHooks && !installedTools.contains(tool))
        }
    }

    // MARK: Editors and terminal
    private var xcodeDetail: String {
        if hasXcodeScripts {
            "\(XcodeBehaviorScripts.scriptCount) scripts in \(ScriptsFolder.xcode.displayPath)"
        } else if isXcodeInstalled {
            "Scripts for Xcode’s Behaviors"
        } else {
            "Install Xcode to use this"
        }
    }

    /// Xcode can only be pointed at the scripts from its own settings, so
    /// Set Up writes them and says where they go, and there's nothing for
    /// MacCove to remove.
    private var xcodeRow: some View {
        toolRow("Xcode", icon: ToolIcon(.xcode), detail: xcodeDetail, isOn: hasXcodeScripts) {
            if hasXcodeScripts {
                Button("Show Scripts") {
                    XcodeBehaviorScripts.showScripts()
                }
            } else {
                Button("Set Up") {
                    XcodeBehaviorScripts.showSetup()
                    refreshXcode()
                    if hasXcodeScripts {
                        Task { await XcodeBehaviorScripts.askToControlXcode() }
                    }
                }
                .disabled(!isXcodeInstalled)
            }
        }
    }

    /// The design's MacCove extension for VS Code doesn't exist yet.
    private var vsCodeRow: some View {
        toolRow("VS Code", icon: ToolIcon(.vsCode), detail: "Installs the MacCove extension", isOn: false) {
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .opacity(0.55)
    }

    private var terminalRow: some View {
        toolRow(
            "Terminal",
            icon: ToolIcon(.terminal),
            detail: hasTerminalHook ? "Hook in ~/.zshrc" : "Adds two lines to ~/.zshrc",
            isOn: hasTerminalHook
        ) {
            Button(hasTerminalHook ? "Remove" : "Set Up") {
                let wasInstalled = hasTerminalHook
                if hasTerminalHook {
                    TerminalHook.remove()
                } else {
                    TerminalHook.showSetup()
                }
                hasTerminalHook = TerminalHook.isInstalled()
                if !wasInstalled, hasTerminalHook {
                    Task { await TerminalWindow.askToControl() }
                }
            }
        }
    }

    /// Off until the hook is set up, since Remove deletes the file this
    /// writes.
    private var terminalThresholdRow: some View {
        Picker("Show commands that run longer than", selection: Binding(
            get: { terminalThreshold },
            set: { seconds in
                terminalThreshold = seconds
                TerminalHook.setThreshold(seconds)
            }
        )) {
            ForEach(TerminalHook.thresholdOptions, id: \.self) { seconds in
                Text(seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute").tag(seconds)
            }
        }
        .disabled(!hasTerminalHook)
    }

    // MARK: Accounts
    private var isGitHubSignedIn: Bool {
        !githubSource.isEmpty && !github.needsSignIn
    }

    private var gitHubDetail: String {
        if isGitHubSignedIn {
            let account = github.login.map { "Signed in as \($0)" } ?? "Signed in"
            let count = GitHubSetup.repositories.count
            let repositories = switch count {
            case 0: "all repositories"
            case 1: "1 repository"
            default: "\(count) repositories"
            }
            return "\(account) · \(repositories)"
        } else if github.needsSignIn {
            return "Sign in again to keep watching pull requests"
        } else {
            return "Uses your gh sign-in, or a token"
        }
    }

    /// Connecting and Repositories ask in their own windows, then update
    /// the row through the monitor and the stored source.
    private var gitHubRow: some View {
        toolRow("GitHub", icon: ToolIcon(.gitHub), detail: gitHubDetail, isOn: isGitHubSignedIn) {
            if isGitHubSignedIn {
                Button("Repositories…") {
                    GitHubSetup.showSetup(monitor: github)
                }
                Button("Sign Out") {
                    GitHubSetup.signOut(monitor: github)
                }
            } else {
                Button(github.needsSignIn ? "Sign In…" : "Connect…") {
                    GitHubSetup.showSetup(monitor: github)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    DeveloperToolsSettingsView()
        .environment(GitHubMonitor())
}
#endif
