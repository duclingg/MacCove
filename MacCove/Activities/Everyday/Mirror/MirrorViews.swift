//
//  MirrorViews.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import AppKit
import AVFoundation
import SwiftUI

private let cameraSymbol = "video.fill"

/// The camera in the left wing and a green dot in the right, like the
/// camera light, for as long as it's on.
struct MirrorCompactView: View {
    let mirror: MirrorCamera
    let notchSize: CGSize

    /// The design's 9pt dot beside a 37pt notch.
    static func dotSize(notch: CGSize) -> CGFloat {
        (notch.height * 0.25).rounded()
    }

    var body: some View {
        let layout = CompactLayout(notch: notchSize)

        HStack(spacing: 0) {
            Image(systemName: cameraSymbol)
                .font(.system(size: (layout.artSize * 0.66).rounded(), weight: .medium))
                .foregroundStyle(.islandSucceeded)
                .frame(width: layout.artSize, height: layout.artSize)
            Spacer(minLength: 0)
            Circle()
                .fill(.islandSucceeded)
                .frame(width: Self.dotSize(notch: notchSize), height: Self.dotSize(notch: notchSize))
                .frame(width: layout.artSize, height: layout.artSize)
        }
        .padding(.horizontal, layout.sideInset)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mirror, camera on")
        .accessibilityAddTraits(.isButton)
        .frame(width: NotchViewModel.compactWidth(notch: notchSize), height: notchSize.height)
    }
}

/// The camera in a bubble beside another activity, green while it's on.
struct MirrorMinimalView: View {
    let notchSize: CGSize

    var body: some View {
        let layout = BubbleLayout(notch: notchSize)

        Image(systemName: cameraSymbol)
            .font(.system(size: (layout.artSize * 0.66).rounded(), weight: .medium))
            .foregroundStyle(.islandSucceeded)
            .frame(width: layout.artSize, height: layout.artSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mirror, camera on")
            .accessibilityAddTraits(.isButton)
    }
}

/// Opened up: which camera, a button to close it, and what it sees,
/// mirrored, as a mirror would show you. Only on your screen; nothing is
/// recorded.
struct MirrorExpandedView: View {
    let mirror: MirrorCamera
    let notchHeight: CGFloat

    private static let headerHeight: CGFloat = 56
    private static let previewGap: CGFloat = 12
    private static let previewHeight: CGFloat = 180
    private static let previewCornerRadius: CGFloat = 18
    private static let bottomGap: CGFloat = 14

    static var bodyHeight: CGFloat {
        NotchViewModel.expandedTopGap + headerHeight + previewGap + previewHeight + bottomGap
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
                .padding(.top, Self.previewGap)
        }
        .padding(.horizontal, NotchViewModel.expandedInset)
        .padding(.top, notchHeight + NotchViewModel.expandedTopGap)
        .frame(width: NotchViewModel.expandedWidth, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: cameraSymbol)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mirror")
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.islandSecondary)
                    .truncationMode(.tail)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button {
                mirror.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Mirror")
        }
        .frame(height: Self.headerHeight)
    }

    private var subtitle: String {
        switch mirror.status {
        case .starting: "Turning the camera on…"
        case .running: mirror.cameraName ?? "Camera"
        case .denied: "Needs access to the camera"
        case .noCamera: "No camera connected"
        }
    }

    // MARK: - What the camera sees

    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: Self.previewCornerRadius, style: .continuous)

        return ZStack(alignment: .topLeading) {
            shape.fill(.white.opacity(0.08))
            switch mirror.status {
            case .running:
                CameraPreview(session: mirror.session)
                    .transition(.opacity)
                badge
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                message(
                    "MacCove can’t use the camera",
                    detail: "Turn on MacCove in Privacy & Security › Camera",
                    button: "Allow…"
                ) {
                    MirrorCamera.openAccessSettings()
                }
            case .noCamera:
                message("No camera connected", detail: "Connect one, and it shows here", button: nil, action: nil)
            }
        }
        .frame(height: Self.previewHeight)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.2), value: mirror.status)
    }

    /// Over the picture, so it's clear no one else is watching.
    private var badge: some View {
        Text("Only you can see this")
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.black.opacity(0.45)))
            .padding(10)
    }

    private func message(_ title: String, detail: String, button: String?, action: (() -> Void)?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.islandSecondary)
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.islandSecondary)
            if let button, let action {
                Button(action: action) {
                    Text(button)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 16)
                        .frame(height: 30)
                        .background(Capsule().fill(.white.opacity(0.14)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The capture session's own preview layer, filling the space and flipped
/// as a mirror is.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session)
    }

    func updateNSView(_ view: CameraPreviewView, context: Context) {
        view.mirror()
    }
}

private final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        wantsLayer = true
        // A camera swapped in, one unplugged for another, brings a new
        // connection to mirror. Removed by itself when the view goes.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionDidStart(_:)),
            name: AVCaptureSession.didStartRunningNotification,
            object: session
        )
        mirror()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Posted on the session's own queue.
    @objc private nonisolated func sessionDidStart(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.mirror()
        }
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    /// Left is left, as in a mirror, whichever way macOS would show it.
    func mirror() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .image
    }

    override func accessibilityLabel() -> String? {
        "Camera preview"
    }

    override func isAccessibilityElement() -> Bool {
        true
    }
}
