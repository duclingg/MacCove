//
//  UpdateChecker.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// New versions of MacCove, from its releases on GitHub.
///
/// Checks when asked, or once a day while Check for Updates Automatically
/// is on, and asks before anything's downloaded: Download opens the
/// release's download, and the new version replaces this one like any
/// other app. Nothing is installed in the background. A MacCove installed
/// with Homebrew leaves updates to `brew upgrade`, so it never checks.
@Observable
final class UpdateChecker {
    nonisolated struct Release: Identifiable, Equatable, Sendable {
        let id: Int
        /// "1.1", without the tag's "v".
        let version: String
        let title: String
        let notes: String
        let publishedAt: Date
        let isPrerelease: Bool
        let pageURL: URL
        /// The disk image or zip attached to it, when there is one.
        let downloadURL: URL?
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// Read off the main actor too, when fetching the releases.
    nonisolated static let repository = "duclingg/MacCove"
    static let automaticKey = "UpdatesCheckAutomatically"
    static let betaKey = "UpdatesIncludeBetas"
    private static let lastCheckedKey = "UpdatesLastChecked"
    private static let skippedVersionKey = "UpdatesSkippedVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: Status = .idle
    private(set) var lastChecked = UserDefaults.standard.object(forKey: UpdateChecker.lastCheckedKey) as? Date
    /// The newest releases first, for the release notes.
    private(set) var releases: [Release] = []

    @ObservationIgnored private var automaticChecks: Task<Void, Never>?

    /// This MacCove, as "1.0", and its build, as "12".
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// Homebrew keeps a cask's files in its Caskroom.
    static var isInstalledWithHomebrew: Bool {
        ["/opt/homebrew/Caskroom/maccove", "/usr/local/Caskroom/maccove"]
            .contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var checksAutomatically: Bool {
        UserDefaults.standard.object(forKey: automaticKey) as? Bool ?? true
    }

    static var includesBetas: Bool {
        UserDefaults.standard.bool(forKey: betaKey)
    }

    // MARK: - Checking

    /// From launch: checks once a day while it's on, asking about anything
    /// new that wasn't skipped.
    func startAutomaticChecks() {
        guard automaticChecks == nil, !Self.isInstalledWithHomebrew else { return }
        automaticChecks = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Self.checksAutomatically, self.isCheckDue {
                    await self.check()
                    if case let .available(release) = self.status,
                       UserDefaults.standard.string(forKey: Self.skippedVersionKey) != release.version {
                        self.offer(release)
                    }
                }
                // Looked at again each hour, so a Mac that slept through
                // the day still checks soon after it wakes.
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private var isCheckDue: Bool {
        guard let lastChecked else { return true }
        return Date.now.timeIntervalSince(lastChecked) >= Self.checkInterval
    }

    /// Asks GitHub for the releases, and whether one is newer than this
    /// MacCove: the newest, or the newest that isn't a beta unless betas
    /// are included.
    func check() async {
        guard status != .checking else { return }
        status = .checking
        do {
            let all = try await Self.fetchReleases()
            let shown = Self.includesBetas ? all : all.filter { !$0.isPrerelease }
            releases = Array(shown.prefix(5))
            if let newest = shown.first, Self.isVersion(newest.version, newerThan: Self.currentVersion) {
                status = .available(newest)
            } else {
                status = .upToDate
            }
            lastChecked = .now
            UserDefaults.standard.set(lastChecked, forKey: Self.lastCheckedKey)
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    /// Opens the download, or the release's page when it has none.
    func download(_ release: Release) {
        NSWorkspace.shared.open(release.downloadURL ?? release.pageURL)
    }

    /// Found by an automatic check: asked about, never downloaded on its own.
    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "MacCove \(release.version) Is Available"
        let notes = Self.summary(of: release.notes)
        alert.informativeText = "You have \(Self.currentVersion)." + (notes.isEmpty ? "" : "\n\n\(notes)")
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            download(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Self.skippedVersionKey)
        default:
            break
        }
    }

    // MARK: - GitHub

    private nonisolated struct GitHubRelease: Decodable {
        let id: Int
        let tagName: String
        let name: String?
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let publishedAt: Date?
        let htmlUrl: URL
        let assets: [Asset]

        nonisolated struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
    }

    private nonisolated enum CheckError: Error {
        case status(Int)
    }

    private nonisolated static func fetchReleases() async throws -> [Release] {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=20") else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw CheckError.status(http.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
            .filter { !$0.draft }
            .map { release in
                let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
                let download = release.assets.first { $0.name.hasSuffix(".dmg") } ?? release.assets.first { $0.name.hasSuffix(".zip") }
                return Release(
                    id: release.id,
                    version: version,
                    title: release.name?.isEmpty == false ? release.name! : version,
                    notes: release.body ?? "",
                    publishedAt: release.publishedAt ?? .distantPast,
                    isPrerelease: release.prerelease,
                    pageURL: release.htmlUrl,
                    downloadURL: download?.browserDownloadUrl
                )
            }
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? CheckError, case let .status(code) = error {
            // Unsigned-in checks are limited to 60 an hour.
            return code == 403 || code == 429 ? "GitHub is busy. Try again in a while." : "GitHub answered \(code)."
        }
        if let error = error as? URLError, error.code == .notConnectedToInternet {
            return "You’re offline."
        }
        return "Couldn’t reach GitHub."
    }

    // MARK: - Versions

    /// "1.10" is newer than "1.9". A beta, "1.1-beta.2", is older than the
    /// release it leads up to.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let (candidateNumbers, candidateIsBeta) = parse(candidate)
        let (currentNumbers, currentIsBeta) = parse(current)
        for index in 0..<max(candidateNumbers.count, currentNumbers.count) {
            let a = index < candidateNumbers.count ? candidateNumbers[index] : 0
            let b = index < currentNumbers.count ? currentNumbers[index] : 0
            if a != b {
                return a > b
            }
        }
        return currentIsBeta && !candidateIsBeta
    }

    private nonisolated static func parse(_ version: String) -> ([Int], isBeta: Bool) {
        let parts = version.split(separator: "-", maxSplits: 1)
        let numbers = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        return (numbers, parts.count > 1)
    }

    /// The first few lines of a release's notes, without Markdown's marks.
    nonisolated static func summary(of notes: String, lines: Int = 4) -> String {
        notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "#*-> "))
                    .replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
            }
            .prefix(lines)
            .joined(separator: "\n")
    }
}
