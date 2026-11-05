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

    @State private var installedTools: Set<AITool> = []
    @State private var toolsWithHooks: Set<AITool> = []
    @State private var isXcodeInstalled = false
    @State private var hasXcodeScripts = false
    @State private var hasTerminalHook = false
    @State private var gitHubToken = ""
    @State private var gitHubRepositories = GitHubSetup.repositories.joined(separator: ", ")
    @State private var gitHubError: String?
    /// Use Token was clicked, so its spinner is the one to show.
    @State private var isUsingToken = false

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
                if isGitHubSignedIn {
                    gitHubRepositoriesRow
                } else {
                    gitHubTokenRow
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(isGitHubSignedIn
                    ? "Remove takes out only what Set Up added. Leave Repositories empty to watch them all."
                    : "Connect uses your GitHub CLI sign-in, and guides signing in with gh in the notch if there isn’t one. Or paste a fine-grained token with read access to pull requests, checks and commit statuses, plus write access to contents and actions for Merge and Re-run Failed. It’s kept in your login keychain.")
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
    private var xcodeSetup: XcodeSetupProgress { .shared }

    /// The row says what MacCove has heard from Xcode, so a half-done
    /// setup is easy to finish: Set Up, in the notch, until every event is
    /// added, then On. Controlling Xcode turned off says so first.
    private enum XcodeState {
        case notInstalled
        case notSetUp
        case cantControl
        case partly
        case on
    }

    private var xcodeState: XcodeState {
        if !hasXcodeScripts {
            return isXcodeInstalled ? .notSetUp : .notInstalled
        }
        if xcodeSetup.control == .denied { return .cantControl }
        return xcodeSetup.isComplete ? .on : .partly
    }

    private var xcodeDetail: String {
        switch xcodeState {
        case .notInstalled: "Install Xcode to use this"
        case .notSetUp: "Scripts for Xcode’s Behaviors"
        case .cantControl: "Builds show without the scheme, Stop or Run"
        case .partly:
            xcodeSetup.count == 0
                ? "Not added in Xcode’s Behaviors yet"
                : "\(xcodeSetup.count) of \(xcodeSetup.total) added · \(xcodeSetup.summary)"
        case .on: "\(XcodeBehaviorScripts.scriptCount) scripts in \(ScriptsFolder.xcode.displayPath)"
        }
    }

    private var xcodeRow: some View {
        HStack(spacing: 12) {
            toolLabel("Xcode", detail: xcodeDetail) {
                ToolIcon(.xcode)
            }
            Spacer(minLength: 0)
            switch xcodeState {
            case .on:
                onStatus
            case .partly:
                statusDot("Partly set up", color: .orange)
            case .cantControl:
                statusDot("Can’t control Xcode", color: .red)
            case .notSetUp, .notInstalled:
                EmptyView()
            }
            switch xcodeState {
            case .notSetUp, .notInstalled, .partly:
                // Setting up happens in the notch, where the steps stay in
                // view above Xcode's Settings; it picks up where it was.
                Button("Set Up") {
                    XcodeBehaviorScripts.guideInNotch()
                    refreshXcode()
                }
                .disabled(xcodeState == .notInstalled)
                .help("Shows the steps in the notch, where they stay in view above Xcode")
            case .on:
                Button("Show Scripts") {
                    XcodeBehaviorScripts.showScripts()
                }
            case .cantControl:
                Button("Open Privacy Settings") {
                    AutomationPermission.openSettings()
                }
            }
        }
        .task {
            xcodeSetup.refreshBehaviors()
            await xcodeSetup.refreshControl()
        }
    }

    private func statusDot(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .frame(width: 8, height: 8)
            Text(text)
        }
        .foregroundStyle(color)
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
                    TerminalHook.setUp()
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
    /// From the moment GitHub accepts the sign-in, before the account's
    /// details have loaded.
    private var isGitHubSignedIn: Bool {
        GitHubConnection.shared.isConnected && !github.needsSignIn
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

    /// Connecting happens here or in the notch, never in a window of its
    /// own: Connect uses the GitHub CLI, the token row below takes a token.
    private var gitHubRow: some View {
        toolRow("GitHub", icon: ToolIcon(.gitHub), detail: gitHubDetail, isOn: isGitHubSignedIn) {
            if isGitHubSignedIn {
                Button("Sign Out") {
                    GitHubSetup.signOut(monitor: github)
                }
            } else {
                // Signing in: the button gives way to a spinner until
                // it's done, so there's one sign-in at a time.
                if isWaitingForGitHub, !isUsingToken {
                    Text(isGitHubSignInGuideShowing ? "Waiting for gh auth login" : "Signing in…")
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(github.needsSignIn ? "Sign In" : "Connect") {
                        Task {
                            await GitHubSetup.connect(monitor: github)
                        }
                    }
                    .disabled(isWaitingForGitHub)
                }
            }
        }
    }

    /// The notch is guiding gh auth login, and connects once it's done.
    private var isGitHubSignInGuideShowing: Bool {
        NotchGuides.shared.isShowing(GitHubSetup.signInGuideID)
    }

    /// Checking a sign-in with GitHub, or waiting for one from gh.
    private var isWaitingForGitHub: Bool {
        GitHubConnection.shared.isBusy
    }

    /// Which repositories to watch, saved as you press Return or leave the
    /// field.
    private var gitHubRepositoriesRow: some View {
        TextField("Repositories", text: $gitHubRepositories, prompt: Text("All repositories, or owner/name, owner/name"))
            .onSubmit {
                GitHubSetup.setRepositories(gitHubRepositories, monitor: github)
            }
            .onDisappear {
                GitHubSetup.setRepositories(gitHubRepositories, monitor: github)
            }
    }

    private var gitHubTokenRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SecureField("Or use a token", text: $gitHubToken, prompt: Text("github_pat_…"))
                    .onSubmit(connectWithToken)
                if isUsingToken {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Use Token", action: connectWithToken)
                        .disabled(gitHubToken.isEmpty || isWaitingForGitHub)
                }
            }
            if let gitHubError {
                Text(gitHubError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }

    private func connectWithToken() {
        guard !isWaitingForGitHub, !gitHubToken.isEmpty else { return }
        isUsingToken = true
        gitHubError = nil
        Task {
            gitHubError = await GitHubSetup.connect(token: gitHubToken, monitor: github)
            if gitHubError == nil {
                gitHubToken = ""
            }
            isUsingToken = false
        }
    }
}

#if DEBUG
#Preview {
    DeveloperToolsSettingsView()
        .environment(GitHubMonitor())
}
#endif
