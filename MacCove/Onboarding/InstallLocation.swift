//
//  InstallLocation.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit

/// Where this copy of MacCove is running from, for the two steps before
/// the welcome: copying it out of the disk image it was opened from, or
/// putting that disk image away once it's been copied.
enum InstallLocation: Equatable {
    /// Opened straight from the disk image, or from the read-only copy
    /// Gatekeeper runs it from instead. It's gone once the image is
    /// ejected, and can't open at login or install the helper.
    case diskImage
    /// Copied out, with the disk image it came on still mounted at
    /// `volume`. `image` is the .dmg behind it, when hdiutil says.
    case leftoverImage(volume: URL, image: URL?)
    case installed

    /// A disk image that's mounted, and where.
    nonisolated private struct MountedImage: Sendable {
        let mountPoint: String
        let image: URL
    }

    static func current() async -> InstallLocation {
        let app = Bundle.main.bundleURL
        let appPath = app.path(percentEncoded: false)
        // Gatekeeper runs a quarantined app opened from a disk image from
        // a randomised read-only folder, not from the image itself.
        if appPath.contains("/AppTranslocation/") {
            return .diskImage
        }
        let images = await mountedImages()
        if images.contains(where: { appPath.hasPrefix($0.mountPoint) }) {
            return .diskImage
        }
        let appName = app.lastPathComponent
        let leftover = images.first { image in
            FileManager.default.fileExists(atPath: image.mountPoint + appName)
        }
        guard let leftover else { return .installed }
        return .leftoverImage(volume: URL(filePath: leftover.mountPoint, directoryHint: .isDirectory), image: leftover.image)
    }

    /// In Applications, or in the Applications folder in your home folder.
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let home = URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory).path(percentEncoded: false)
        return path == "/Applications/" || path == home
    }

    // MARK: - Copying

    /// Copies MacCove into Applications, or ~/Applications when that isn't
    /// yours to write to, then opens the copy and quits this one. A
    /// MacCove already there goes to the Trash first, so it can be got
    /// back.
    static func copyToApplicationsAndRelaunch() throws {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        var folder = URL(filePath: "/Applications", directoryHint: .isDirectory)
        if !fileManager.isWritableFile(atPath: folder.path(percentEncoded: false)) {
            folder = URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appending(path: source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)

        // Opened once this one has quit, so the two never both hold the
        // agent socket. The shell outlives MacCove.
        let relaunch = Process()
        relaunch.executableURL = URL(filePath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", destination.path(percentEncoded: false)]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Cleaning up

    /// Ejects the disk image, then moves the .dmg to the Trash rather than
    /// deleting it, so it can be got back.
    static func cleanUp(volume: URL, image: URL?) throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        if let image, FileManager.default.fileExists(atPath: image.path(percentEncoded: false)) {
            try FileManager.default.trashItem(at: image, resultingItemURL: nil)
        }
    }

    // MARK: - Disk images

    /// Every mounted disk image's mount points, from `hdiutil info`, each
    /// ending in a slash so /Volumes/MacCove doesn't match
    /// /Volumes/MacCove 1.
    nonisolated private static func mountedImages() async -> [MountedImage] {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let images = plist["images"] as? [[String: Any]] else { return [] }
            return images.flatMap { image -> [MountedImage] in
                guard let path = image["image-path"] as? String else { return [] }
                let entities = image["system-entities"] as? [[String: Any]] ?? []
                return entities.compactMap { $0["mount-point"] as? String }.map { mountPoint in
                    MountedImage(
                        mountPoint: mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/",
                        image: URL(filePath: path)
                    )
                }
            }
        }.value
    }
}
