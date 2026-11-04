//
//  XcodeBuildLogs.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import Foundation

/// An error from a build or a failed test, as Xcode's issue navigator
/// lists it.
nonisolated struct XcodeBuildIssue: Sendable, Equatable {
    /// "IslandView.swift:48" for an error, the test's name for a failure.
    let location: String
    let message: String
}

/// What Xcode leaves on disk about builds and tests, in the workspace's
/// DerivedData folder: the build log manifest (scheme, times, error and
/// warning counts), the compressed build log the errors are read from, and
/// the test result bundles. Only the last has a supported reader
/// (`xcresulttool`), so every read gives up quietly and the island makes do
/// without the details.
nonisolated enum XcodeBuildLogs {
    struct Entry: Sendable, Equatable {
        let logURL: URL
        let scheme: String?
        let startedAt: Date
        let stoppedAt: Date
        let errorCount: Int
        let warningCount: Int
        /// "S" for succeeded, "W" for succeeded with warnings, "E" for errors.
        let status: String?

        var succeeded: Bool {
            status == "S" || status == "W"
        }
    }

    /// The newest build log that started at or after `date`, once Xcode has
    /// finished writing it. Background builds for previews and indexing
    /// ("Build (Automatic)") never count.
    @concurrent
    static func latestEntry(workspacePath: String?, since date: Date) async -> Entry? {
        guard let folder = derivedDataFolder(workspacePath: workspacePath) else { return nil }
        let logs = folder.appending(path: "Logs/Build", directoryHint: .isDirectory)
        guard let data = try? Data(contentsOf: logs.appending(path: "LogStoreManifest.plist")),
              let manifest = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entries = manifest["logs"] as? [String: [String: Any]] else { return nil }

        // A little slack for the time between Xcode starting the build and
        // the behavior's script reaching MacCove.
        let earliest = date.timeIntervalSinceReferenceDate - 5
        return entries.values
            .compactMap { entry -> Entry? in
                guard let fileName = entry["fileName"] as? String,
                      let started = entry["timeStartedRecording"] as? Double, started >= earliest,
                      let stopped = entry["timeStoppedRecording"] as? Double, stopped >= started,
                      (entry["title"] as? String)?.contains("(Automatic)") != true else { return nil }
                let counts = entry["primaryObservable"] as? [String: Any]
                return Entry(
                    logURL: logs.appending(path: fileName),
                    scheme: entry["schemeIdentifier-schemeName"] as? String,
                    startedAt: Date(timeIntervalSinceReferenceDate: started),
                    stoppedAt: Date(timeIntervalSinceReferenceDate: stopped),
                    errorCount: counts?["totalNumberOfErrors"] as? Int ?? 0,
                    warningCount: counts?["totalNumberOfWarnings"] as? Int ?? 0,
                    status: counts?["highLevelStatus"] as? String
                )
            }
            .max { $0.startedAt < $1.startedAt }
    }

    /// The first `limit` errors in the build log that point at a line of a
    /// file, and how many such errors there are in all. Read from the
    /// compiler's own output in the log, `path:line:column: error: message`,
    /// which is the part of the log least likely to change.
    @concurrent
    static func errors(in entry: Entry, limit: Int) async -> (first: [XcodeBuildIssue], total: Int) {
        guard let log = decompress(entry.logURL) else { return ([], 0) }
        let text = String(decoding: log, as: UTF8.self) as NSString
        let errorPattern = try! NSRegularExpression(pattern: #"(/[^"\r\n]+):(\d+):(?:\d+:)? error: ([^\r\n]+)"#)
        var seen = Set<String>()
        var issues: [XcodeBuildIssue] = []
        var total = 0
        errorPattern.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match,
                  let line = Int(text.substring(with: match.range(at: 2))) else { return }
            let path = text.substring(with: match.range(at: 1))
            let message = cleanMessage(text.substring(with: match.range(at: 3)))
            // The same error shows up more than once in the log.
            guard seen.insert("\(path):\(line):\(message)").inserted else { return }
            total += 1
            if issues.count < limit {
                issues.append(XcodeBuildIssue(location: "\((path as NSString).lastPathComponent):\(line)", message: message))
            }
        }
        return (issues, total)
    }

    struct TestSummary: Sendable {
        let total: Int
        let failed: Int
        /// Only the first few, as many as were asked for.
        let failures: [XcodeBuildIssue]
        /// The bundle is there while the tests run, without a finish time.
        let isFinished: Bool
    }

    /// The newest test results created at or after `date`, read with
    /// `xcresulttool`.
    @concurrent
    static func latestTestSummary(workspacePath: String?, since date: Date, failureLimit: Int) async -> TestSummary? {
        guard let folder = derivedDataFolder(workspacePath: workspacePath) else { return nil }
        let tests = folder.appending(path: "Logs/Test", directoryHint: .isDirectory)
        let earliest = date.addingTimeInterval(-5)
        guard let bundles = try? FileManager.default.contentsOfDirectory(at: tests, includingPropertiesForKeys: [.creationDateKey]) else {
            return nil
        }
        let newest = bundles
            .filter { $0.pathExtension == "xcresult" }
            .compactMap { bundle -> (url: URL, created: Date)? in
                guard let created = (try? bundle.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created >= earliest else { return nil }
                return (bundle, created)
            }
            .max { $0.created < $1.created }
        guard let newest,
              let data = output(of: "/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "summary", "--path", newest.url.path(percentEncoded: false), "--compact"]),
              let summary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let failures = (summary["testFailures"] as? [[String: Any]] ?? [])
            .prefix(failureLimit)
            .compactMap { failure -> XcodeBuildIssue? in
                guard let name = failure["testName"] as? String else { return nil }
                let text = (failure["failureText"] as? String ?? "")
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return XcodeBuildIssue(location: name, message: text)
            }
        return TestSummary(
            total: summary["totalTestCount"] as? Int ?? 0,
            failed: summary["failedTests"] as? Int ?? 0,
            failures: Array(failures),
            isFinished: summary["finishTime"] != nil
        )
    }

    /// The build configuration the scheme runs with ("Debug"), from its
    /// `.xcscheme` file, shared or the user's own. `nil` for schemes Xcode
    /// makes up as it goes, like a Swift package's.
    @concurrent
    static func configuration(workspacePath: String, scheme: String) async -> String? {
        let fileManager = FileManager.default
        let workspace = URL(filePath: workspacePath)
        var containers = [workspace]
        if workspace.pathExtension == "xcworkspace",
           let siblings = try? fileManager.contentsOfDirectory(at: workspace.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
            containers += siblings.filter { $0.pathExtension == "xcodeproj" }
        }

        for container in containers {
            var candidates = [container.appending(path: "xcshareddata/xcschemes/\(scheme).xcscheme")]
            let userData = container.appending(path: "xcuserdata", directoryHint: .isDirectory)
            if let users = try? fileManager.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil) {
                candidates += users.map { $0.appending(path: "xcschemes/\(scheme).xcscheme") }
            }
            for candidate in candidates {
                guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
                let text = contents as NSString
                let launchConfigurationPattern = try! NSRegularExpression(pattern: #"<LaunchAction[^>]*?buildConfiguration\s*=\s*"([^"]+)""#)
                if let match = launchConfigurationPattern.firstMatch(in: contents, range: NSRange(location: 0, length: text.length)) {
                    return text.substring(with: match.range(at: 1))
                }
            }
        }
        return nil
    }

    /// The workspace or project itself. Xcode reports a plain project's
    /// workspace as the `project.xcworkspace` inside it, and DerivedData
    /// records the project.
    static func normalizedPath(_ path: String) -> String {
        let url = URL(filePath: path).standardizedFileURL
        if url.lastPathComponent == "project.xcworkspace", url.deletingLastPathComponent().pathExtension == "xcodeproj" {
            return url.deletingLastPathComponent().path(percentEncoded: false)
        }
        return url.path(percentEncoded: false)
    }

    /// "MacCove" for MacCove.xcodeproj, and a Swift package's folder name
    /// for the workspace Xcode keeps inside it.
    static func displayName(workspacePath: String) -> String {
        let url = URL(filePath: workspacePath)
        if url.lastPathComponent == "package.xcworkspace" {
            // Package/.swiftpm/xcode/package.xcworkspace
            return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Capitalised the way Xcode's issue navigator shows it, without the
    /// diagnostic group Swift adds at the end ("[#IsolatedConformances]").
    private static func cleanMessage(_ message: String) -> String {
        var trimmed = message.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("]"), let group = trimmed.range(of: " [#", options: .backwards) {
            trimmed = String(trimmed[..<group.lowerBound])
        }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// Xcode's own setting if it has moved DerivedData somewhere absolute,
    /// otherwise the usual place.
    private static var derivedDataRoot: URL {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
           custom.hasPrefix("/") {
            return URL(filePath: custom, directoryHint: .isDirectory)
        }
        return URL.libraryDirectory.appending(path: "Developer/Xcode/DerivedData", directoryHint: .isDirectory)
    }

    /// Each workspace's folder names the workspace in its `info.plist`.
    /// Without a workspace to look for, the one built most recently.
    private static func derivedDataFolder(workspacePath: String?) -> URL? {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: derivedDataRoot, includingPropertiesForKeys: nil) else {
            return nil
        }
        guard let workspacePath else {
            return folders.max { manifestDate($0) < manifestDate($1) }
        }
        return folders.first { folder in
            guard let info = NSDictionary(contentsOf: folder.appending(path: "info.plist")),
                  let path = info["WorkspacePath"] as? String else { return false }
            return normalizedPath(path) == workspacePath
        }
    }

    private static func manifestDate(_ folder: URL) -> Date {
        let manifest = folder.appending(path: "Logs/Build/LogStoreManifest.plist")
        return (try? manifest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Build logs are gzipped.
    private static func decompress(_ url: URL) -> Data? {
        output(of: "/usr/bin/gzip", ["-dc", url.path(percentEncoded: false)])
    }

    /// What a command prints, or `nil` if it fails.
    private static func output(of executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting, or output bigger than the pipe's buffer would
        // never let the command finish.
        let data = try? output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
