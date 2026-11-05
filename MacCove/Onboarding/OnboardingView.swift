//
//  OnboardingView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/4/26.
//

import SwiftUI

/// The welcome card: black, hanging from the top edge with the notch's
/// ears, so it reads as the notch grown down. It drops out at the notch's
/// size, springs to each step's width with its height following what's in
/// it, and folds back up at the end. On Done, an arrow points at the menu
/// bar item.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .top) {
            if model.step == .done, model.isOpen, let point = model.menuItemPoint {
                MenuItemArrow(
                    from: CGPoint(x: model.cardFrame.maxX + 10, y: model.cardFrame.minY + 64),
                    to: CGPoint(x: point.x, y: point.y + 6)
                )
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 5]))
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.25).delay(0.2)))
                .accessibilityHidden(true)
            }
            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: The card

    private var radius: CGFloat {
        model.isOpen ? 32 : (model.hasNotch || model.isPill ? 10 : 0)
    }

    /// The notch, or on a display without one, nothing yet: it drops from
    /// the top edge.
    /// At the end on a display without one, the pill where activities
    /// show, before it slides away.
    private var closedSize: CGSize {
        if model.hasNotch || model.isPill {
            return model.notchSize
        }
        return CGSize(width: model.step.width * 0.6, height: 0)
    }

    /// Clear of the camera housing.
    private var contentTop: CGFloat {
        model.hasNotch ? model.notchSize.height + 16 : 28
    }

    private var card: some View {
        let width = model.step.width
        return VStack(alignment: .leading, spacing: 0) {
            // Overlapping, so the step fading out doesn't push the next down.
            ZStack(alignment: .topLeading) {
                OnboardingStepView(model: model)
                    .id(model.step)
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
            if let installError = model.installError {
                Text(installError)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.islandError)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            // What would show in the notch, while the card has its place:
            // Xcode's setup, the rest of another, or something MacCove has
            // to say.
            if let xcode = model.xcode, xcode.guide != nil {
                XcodeGuideView(xcode: xcode, notchHeight: 0, isEmbedded: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
                    .padding(.top, 16)
                    .transition(.opacity)
            }
            if let guide = model.guide {
                NotchGuideContent(guide: guide) { action in
                    NotchGuides.shared.perform(action, in: guide)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.07)))
                .padding(.top, 16)
                .transition(.opacity)
            }
            footer
                .padding(.top, 20)
        }
        .padding(.top, contentTop)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(model.isOpen ? 1 : 0)
        .animation(model.isOpen ? Animation.easeOut(duration: 0.2).delay(0.14) : Animation.easeIn(duration: 0.12), value: model.isOpen)
        .frame(width: model.isOpen ? width : closedSize.width, height: model.isOpen ? nil : closedSize.height, alignment: .top)
        .clipShape(IslandBodyShape(cornerRadius: radius))
        .background {
            IslandShape(cornerRadius: radius)
                .fill(.black)
                .padding(.horizontal, -IslandShape.earWidth)
                .shadow(color: .black.opacity(model.isOpen ? 0.45 : 0), radius: 32, y: 24)
                // With no notch to grow from, even the ears wait to drop.
                .opacity(model.isOpen || model.hasNotch || model.isPill ? 1 : 0)
        }
        // At the end without a notch, the pill leaves by sliding up past
        // the top edge whole, rather than shrinking, which would flatten
        // its corners ahead of its middle.
        .offset(y: model.isSlidAway ? -(closedSize.height + IslandShape.earWidth + 4) : 0)
        .animation(.island, value: model.isOpen)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            model.cardFrame = frame
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MacCove setup")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let progress = model.progress {
                HStack(spacing: 6) {
                    ForEach(0..<progress.count, id: \.self) { index in
                        Capsule()
                            .fill(dotColor(index, current: progress.current))
                            .frame(width: index == progress.current ? 18 : 6, height: 6)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Step \(progress.current + 1) of \(progress.count)")
            }
            Spacer(minLength: 0)
            if let secondary = model.secondaryTitle {
                Button(secondary) {
                    model.secondaryAction()
                }
                .buttonStyle(OnboardingButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
                .disabled(model.isWorking)
            }
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .accessibilityLabel(model.step == .move ? "Copying MacCove" : "Cleaning up")
            }
            Button(model.primaryTitle) {
                model.primaryAction()
            }
            .buttonStyle(OnboardingButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .disabled(model.isWorking)
        }
        .frame(height: 36)
    }

    private func dotColor(_ index: Int, current: Int) -> Color {
        if index == current { return .white }
        return .white.opacity(index < current ? 0.55 : 0.22)
    }
}

// MARK: - Arrow

/// A dashed curve from beside the card up to the menu bar item, arriving
/// straight up so the head points at it.
nonisolated private struct MenuItemArrow: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addCurve(
            to: to,
            control1: CGPoint(x: from.x + (to.x - from.x) * 0.6, y: from.y),
            control2: CGPoint(x: to.x, y: to.y + 40)
        )
        path.move(to: CGPoint(x: to.x - 6, y: to.y + 9))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: to.x + 6, y: to.y + 9))
        return path
    }
}

// MARK: - Styles

/// The card's colours: white text, and the greys macOS uses on black.
enum OnboardingStyle {
    static let secondary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.62)
    static let tertiary = Color(red: 235 / 255, green: 235 / 255, blue: 245 / 255).opacity(0.45)
    static let separator = Color.white.opacity(0.1)
    static let fill = Color.white.opacity(0.07)
    static let link = Color(red: 100 / 255, green: 168 / 255, blue: 1)
    static let mono = Font.system(size: 12, design: .monospaced)
}

/// Pill buttons: white for the step's main button, translucent for the rest.
struct OnboardingButtonStyle: ButtonStyle {
    enum Kind {
        /// The footer's main button.
        case primary
        /// The footer's Back, Cancel and Not Now.
        case secondary
        /// Allow and Install in a row.
        case row
        /// Set Up and Allow on a tile.
        case tile
    }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: kind == .tile ? 12 : 13, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : (isEnabled ? 1 : 0.5))
            .fixedSize()
    }

    private var height: CGFloat {
        switch kind {
        case .primary, .secondary: 36
        case .row: 30
        case .tile: 26
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary: 20
        case .secondary: 18
        case .row: 14
        case .tile: 11
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .white
        case .secondary: .white.opacity(0.12)
        case .row, .tile: .white.opacity(0.14)
        }
    }
}
