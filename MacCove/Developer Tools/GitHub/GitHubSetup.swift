//
//  GitHubSetup.swift
//  MacCove
//
//  Created by Justin Hoang on 11/3/26.
//

import AppKit
import Security

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

    static func showSetup(monitor: GitHubMonitor) {
        Task {
            if source != nil, !monitor.needsSignIn {
                showSignedIn(monitor: monitor)
            } else {
                await connect(monitor: monitor)
            }
        }
    }

    // MARK: - Signed in

    private static func showSignedIn(monitor: GitHubMonitor) {
        let alert = NSAlert()
        alert.messageText = "GitHub in MacCove"
        let account = monitor.login.map { "Signed in as \($0)" } ?? "Signed in"
        let how = source == .cli ? "with your GitHub CLI sign-in" : "with a token"
        alert.informativeText = """
            \(account) \(how). The notch shows checks running on your pull requests, opens when one fails, \
            and says when one is ready to merge or someone asks for your review.

            Repositories to watch, as owner/name separated by commas. Leave it empty to watch them all.
            """
        let field = NSTextField(string: repositories.joined(separator: ", "))
        field.placeholderString = "All repositories"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Sign Out")

        NSApp.activate()
        let choice = alert.runModal()
        if choice == .alertSecondButtonReturn {
            signOut(monitor: monitor)
            return
        }
        let picked = field.stringValue
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { $0.contains("/") }
        if picked != repositories {
            UserDefaults.standard.set(picked, forKey: repositoriesKey)
            monitor.restart()
        }
    }

    static func signOut(monitor: GitHubMonitor) {
        GitHubKeychain.token = nil
        UserDefaults.standard.removeObject(forKey: sourceKey)
        monitor.stop()
    }

    // MARK: - Connecting

    private static func connect(monitor: GitHubMonitor) async {
        let cliToken = await GitHubCLI.token()

        let alert = NSAlert()
        alert.messageText = monitor.needsSignIn ? "Sign In to GitHub Again" : "Connect GitHub"
        var text = """
            The notch shows checks running on your open pull requests, opens when one fails, and says when one \
            is ready to merge or someone asks for your review. MacCove checks every 30 to 60 seconds and only \
            changes anything when you click Merge or Re-run Failed.
            """
        if cliToken == nil {
            text += "\n\nTo use your GitHub CLI sign-in, run gh auth login in a terminal first. Or use a token."
        }
        alert.informativeText = text
        if cliToken != nil {
            alert.addButton(withTitle: "Use GitHub CLI Sign-In")
        }
        alert.addButton(withTitle: "Use a Token…")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate()
        let choice = alert.runModal()
        let usesCLI = cliToken != nil && choice == .alertFirstButtonReturn
        let usesToken = cliToken != nil ? choice == .alertSecondButtonReturn : choice == .alertFirstButtonReturn

        if usesCLI, let cliToken {
            await finishConnecting(with: cliToken, source: .cli, monitor: monitor)
        } else if usesToken, let token = askForToken() {
            await finishConnecting(with: token, source: .token, monitor: monitor)
        }
    }

    private static func askForToken() -> String? {
        let alert = NSAlert()
        alert.messageText = "Paste a GitHub Token"
        alert.informativeText = """
            A fine-grained token needs read access to pull requests, checks and commit statuses on the \
            repositories to watch. For Merge and Re-run Failed, also give it write access to contents and \
            actions. It’s kept in your keychain.
            """
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "github_pat_…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Only kept once GitHub has accepted it.
    private static func finishConnecting(with token: String, source: Source, monitor: GitHubMonitor) async {
        do {
            _ = try await GitHubAPI(token: token).viewerLogin()
        } catch {
            let alert = NSAlert()
            alert.messageText = "MacCove Couldn’t Sign In to GitHub"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
            return
        }
        GitHubKeychain.token = source == .token ? token : nil
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
        monitor.restart()
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
