//
//  MirrorCamera.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import AVFoundation

/// Mirror: the camera, shown only in the notch, to check how you look
/// before a meeting. Nothing is recorded or saved; the frames go straight
/// to the preview and nowhere else.
///
/// Opened from a meeting as it starts, or from Settings. The camera stays
/// on while it's open, with a green dot beside the notch like the camera
/// light, and turns off as soon as it's closed. Left open and out of sight,
/// it closes itself after a minute, and always as the Mac sleeps or locks.
@Observable
final class MirrorCamera {
    enum Event {
        /// Opened.
        case started
        /// Closed, by its button or by itself.
        case ended
    }

    enum Access: Equatable {
        case notDetermined
        case denied
        case granted
    }

    enum Status: Equatable {
        /// Asking for access, or the camera warming up.
        case starting
        /// Frames are coming in.
        case running
        /// Turned off for MacCove in Privacy & Security.
        case denied
        /// No camera connected, or it couldn't be opened.
        case noCamera
    }

    /// Open in the notch, and so the camera is on (or coming on).
    private(set) var isOpen = false
    private(set) var status: Status = .starting
    private(set) var access: Access = MirrorCamera.currentAccess
    /// The camera shown: "FaceTime HD Camera", or an iPhone's.
    private(set) var cameraName: String?

    /// What the preview draws.
    var session: AVCaptureSession { capture.session }
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    /// Whether the notch is showing it, open or under the cursor. Out of
    /// sight for `unseenTimeout`, it closes itself.
    @ObservationIgnored var isInView: () -> Bool = { false }

    private let capture = CaptureSession()
    /// Bumped on every open and close, so a camera that finishes starting
    /// after it was closed again is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watching: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    /// How long it stays on while you're not looking at it.
    static let unseenTimeout: Duration = .seconds(60)
    private static let watchInterval: Duration = .seconds(5)

    init() {
        let center = NotificationCenter.default
        // Another camera takes over when this one is unplugged, and a
        // camera plugged in is used when there was none.
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.camerasChanged() }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.camerasChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    // MARK: - Opening and closing

    /// Turns the camera on, asking for access the first time.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        generation += 1
        status = .starting
        cameraName = nil
        onEvent?(.started)
        watch()
        start(generation: generation)
    }

    /// Turns the camera off straight away.
    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        watching?.cancel()
        capture.stop()
        status = .starting
        cameraName = nil
        onEvent?(.ended)
    }

    private func start(generation: Int) {
        Task { [weak self] in
            guard let self else { return }
            self.refreshPermissions()
            if self.access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                self.refreshPermissions()
            }
            guard self.isOpen, self.generation == generation else { return }
            guard self.access == .granted else {
                self.status = .denied
                return
            }
            let name = await self.capture.start()
            guard self.isOpen, self.generation == generation else { return }
            self.cameraName = name
            self.status = name == nil ? .noCamera : .running
        }
    }

    /// A camera came or went while it's open: start again on whichever is
    /// there now.
    private func camerasChanged() {
        guard isOpen, status == .running || status == .noCamera else { return }
        generation += 1
        // The picture stays until the next camera is ready.
        start(generation: generation)
    }

    /// Closes it once it has been out of sight for a while.
    private func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            var unseenSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard !Task.isCancelled, let self, self.isOpen else { return }
                if self.isInView() {
                    unseenSince = nil
                } else if let since = unseenSince {
                    if ContinuousClock.now - since >= Self.unseenTimeout {
                        self.close()
                        return
                    }
                } else {
                    unseenSince = ContinuousClock.now
                }
            }
        }
    }

    // MARK: - Access

    private static var currentAccess: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func refreshPermissions() {
        let access = Self.currentAccess
        if access != self.access {
            self.access = access
        }
    }

    static func openAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The capture session, started and stopped on a queue of its own, since
/// both block until the camera has turned on or off.
nonisolated private final class CaptureSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.ducling.MacCove.mirror")
    /// Only touched on `queue`.
    private var input: AVCaptureDeviceInput?

    /// The camera FaceTime and the rest would use, so it's the one you'll
    /// be seen through. Returns its name, or `nil` when there's none to
    /// open.
    func start() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
                guard let device else {
                    stopRunning()
                    continuation.resume(returning: nil)
                    return
                }
                // Already showing it: another camera came or went.
                if input?.device.uniqueID == device.uniqueID, session.isRunning {
                    continuation.resume(returning: device.localizedName)
                    return
                }
                guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                    stopRunning()
                    continuation.resume(returning: nil)
                    return
                }
                // Stopped while the camera is swapped, so starting again
                // tells the preview to mirror the new one.
                if input != nil, session.isRunning {
                    session.stopRunning()
                }
                session.beginConfiguration()
                if let input {
                    session.removeInput(input)
                    self.input = nil
                }
                if session.canSetSessionPreset(.high) {
                    session.sessionPreset = .high
                }
                let added = session.canAddInput(newInput)
                if added {
                    session.addInput(newInput)
                    input = newInput
                }
                session.commitConfiguration()
                guard added else {
                    stopRunning()
                    continuation.resume(returning: nil)
                    return
                }
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(returning: device.localizedName)
            }
        }
    }

    /// Turns the camera, and its light, off.
    func stop() {
        queue.async { [self] in
            stopRunning()
        }
    }

    /// On `queue`.
    private func stopRunning() {
        if session.isRunning {
            session.stopRunning()
        }
        removeInput()
    }

    private func removeInput() {
        guard let input else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
        self.input = nil
    }
}

#if DEBUG
extension MirrorCamera {
    /// Shows what's given and stays that way, for SwiftUI previews. The
    /// camera never turns on.
    static func preview(status: Status, cameraName: String? = "FaceTime HD Camera") -> MirrorCamera {
        let camera = MirrorCamera()
        camera.isOpen = true
        camera.status = status
        camera.cameraName = status == .running ? cameraName : nil
        return camera
    }
}
#endif
