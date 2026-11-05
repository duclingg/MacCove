//
//  GitHubSetup.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import Observation
import Security

/// Where connecting GitHub has got, for Settings and the welcome alike:
/// one connect at a time, from either, and connected the moment GitHub
/// accepts the sign-in, before the account's details have loaded.
@Observable
final class GitHubConnection {
    static let shared = GitHubConnection()

    /// Reading the GitHub CLI's sign-in, or checking a sign-in with GitHub.
    fileprivate(set) var isConnecting = false
    fileprivate(set) var isConnected = GitHubSetup.source != nil

    /// Connecting, or waiting in the notch for gh auth login.
    var isBusy: Bool {
        isConnecting || NotchGuides.shared.isShowing(GitHubSetup.signInGuideID)
    }
}

/// Signs MacCove in to GitHub, with the GitHub CLI's sign-in or a token
/// pasted in, and picks the repositories to watch.
///
/// The CLI's token is asked for again each time MacCove starts, so signing
/// out of `gh` signs MacCove out too. A pasted token stays in the keychain.
@MainActor
enum GitHubSetup {
    enum Source: String {
        case cli
        case token
    }

    static let sourceKey = "GitHubSource"
    /// "owner/name" each; empty for every repository.
    static let repositoriesKey = "GitHubRepositories"

    static var source: Source? {
        UserDefaults.standard.string(forKey: sourceKey).flatMap(Source.init)
    }

    static var repositories: [String] {
        UserDefaults.standard.stringArray(forKey: repositoriesKey) ?? []
    }

    /// The token to use now, `nil` when signed out or the CLI no longer
    /// has one.
    static func token() async -> String? {
        switch source {
        case .cli?: await GitHubCLI.token()
        case .token?: GitHubKeychain.token
        case nil: nil
        }
    }

    // MARK: - Signed in

    /// From Settings: "owner/name" each, separated by commas or spaces.
    /// Empty watches them all.
    static func setRepositories(_ text: String, monitor: GitHubMonitor) {
        let picked = text
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { $0.contains("/") }
        guard picked != repositories else { return }
        UserDefaults.standard.set(picked, forKey: repositoriesKey)
        monitor.restart()
    }

    static func signOut(monitor: GitHubMonitor) {
        signInWatch?.cancel()
        NotchGuides.shared.finish(signInGuideID)
        GitHubConnection.shared.isConnected = false
        GitHubKeychain.token = nil
        UserDefaults.standard.removeObject(forKey: sourceKey)
        monitor.stop()
    }

    // MARK: - Connecting

    static let signInGuideID = "github-sign-in"
    private static var signInWatch: Task<Void, Never>?

    /// Connect, from Settings or the welcome. With the GitHub CLI signed
    /// in, that's the one step. Without, signing in takes more, so the
    /// notch guides it and MacCove connects as soon as `gh` has a sign-in.
    /// A token is pasted in Settings instead.
    static func connect(monitor: GitHubMonitor) async {
        let connection = GitHubConnection.shared
        // One at a time: a second click while this goes does nothing.
        guard !connection.isBusy else { return }
        connection.isConnecting = true
        defer { connection.isConnecting = false }
        if let token = await GitHubCLI.token() {
            if let reason = await finishConnecting(with: token, source: .cli, monitor: monitor) {
                NotchGuides.shared.show(.notice(id: signInGuideID, icon: .tool(.gitHub), title: "Couldn’t sign in to GitHub", message: reason, tone: .error))
            }
        } else {
            showSignInGuide(monitor: monitor)
        }
    }

    /// With a token pasted in Settings. Returns why it didn't work, to show
    /// beside the field.
    static func connect(token: String, monitor: GitHubMonitor) async -> String? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "Paste a token first." }
        let connection = GitHubConnection.shared
        guard !connection.isBusy else { return nil }
        connection.isConnecting = true
        defer { connection.isConnecting = false }
        return await finishConnecting(with: token, source: .token, monitor: monitor)
    }

    /// Only kept once GitHub has accepted it. Returns why not.
    @discardableResult
    private static func finishConnecting(with token: String, source: Source, monitor: GitHubMonitor) async -> String? {
        do {
            _ = try await GitHubAPI(token: token).viewerLogin()
        } catch {
            return error.localizedDescription
        }
        GitHubKeychain.token = source == .token ? token : nil
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
        GitHubConnection.shared.isConnected = true
        monitor.restart()
        return nil
    }

    /// Sign in with `gh auth login` in a terminal; MacCove looks for the
    /// sign-in every few seconds and connects once it's there.
    private static func showSignInGuide(monitor: GitHubMonitor) {
        let guides = NotchGuides.shared
        let id = signInGuideID
        guides.show(NotchGuide(
            id: id,
            icon: .tool(.gitHub),
            title: monitor.needsSignIn ? "Sign in to GitHub again" : "Sign in to GitHub",
            subtitle: "With the GitHub CLI, then MacCove connects",
            steps: [
                NotchGuide.Step(
                    id: "login",
                    text: "In a terminal, run gh auth login",
                    detail: GitHubCLI.isInstalled ? "Or paste a token in Settings › Developer Tools" : "Install it first: brew install gh",
                    isWatching: true
                ),
                NotchGuide.Step(id: "connected", text: "MacCove connects by itself", detail: "Once gh has your sign-in"),
            ],
            actions: [
                NotchGuide.Action(title: "Copy Command", finishes: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(GitHubCLI.isInstalled ? "gh auth login" : "brew install gh && gh auth login", forType: .string)
                },
                NotchGuide.Action(title: "Cancel") {
                    signInWatch?.cancel()
                },
            ]
        ))
        signInWatch?.cancel()
        signInWatch = Task {
            // Up to ten minutes.
            for _ in 0..<200 {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, guides.isShowing(id) else { return }
                guard let token = await GitHubCLI.token() else { continue }
                guides.complete(step: "login", in: id)
                // Checking the sign-in with GitHub.
                guides.watch(step: "connected", in: id)
                if let reason = await finishConnecting(with: token, source: .cli, monitor: monitor) {
                    guides.finish(id)
                    guides.show(.notice(id: id, icon: .tool(.gitHub), title: "Couldn’t sign in to GitHub", message: reason, tone: .error))
                    return
                }
                guides.complete(step: "connected", in: id)
                guides.update(id) { guide in
                    guide.title = "GitHub is connected"
                    guide.subtitle = "Pull requests show in the notch"
                    guide.actions = [NotchGuide.Action(title: "Done", isPrimary: true) {}]
                }
                try? await Task.sleep(for: .seconds(4))
                guides.finish(id)
                return
            }
        }
    }
}

/// `gh auth token`, from wherever Homebrew or the installer put `gh`. Apps
/// opened from the Finder don't get the shell's PATH, so it's looked for
/// in the usual places.
nonisolated enum GitHubCLI {
    private static let candidatePaths = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh",
        "/run/current-system/sw/bin/gh",
        URL.homeDirectory.appending(path: ".local/bin/gh").path(percentEncoded: false),
    ]

    static var isInstalled: Bool {
        candidatePaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func token() async -> String? {
        await Task.detached(priority: .utility) { readToken() }.value
    }

    private static func readToken() -> String? {
        guard let path = candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = ["auth", "token", "--hostname", "github.com"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

/// A pasted token, in the login keychain.
enum GitHubKeychain {
    private static let service = "com.ducling.MacCove.github"
    private static let account = "token"

    static var token: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            _ = SecItemDelete(query as CFDictionary)
            guard let newValue, let data = newValue.data(using: .utf8) else { return }
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
