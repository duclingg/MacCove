//
//  IslandView.swift
//  MacCove
//
//  Created by Justin Hoang on 11/2/26.
//

import SwiftUI

/// The island itself. The black silhouette springs between sizes while the
/// content for each state cross-fades in on top at a fixed width, so text
/// never reflows mid-animation.
struct IslandView: View {
    let viewModel: NotchViewModel

    /// Extra distance past the top edge when tucked away, enough to clear
    /// the few points the island grows on hover.
    private static let tuckClearance: CGFloat = 12
    fileprivate static let topBleed: CGFloat = 8

    var body: some View {
        let geometry = viewModel.geometry
        let bubbles = viewModel.bubbles

        ZStack(alignment: .top) {
            // Black above the island's top edge, normally off screen. If the
            // island ever sits a pixel or two low (rounding mid-slide on a
            // scaled display), this fills the gap instead of the wallpaper.
            Rectangle()
                .fill(.black)
                .frame(width: geometry.size.width + IslandShape.earWidth * 2, height: Self.topBleed)
                .offset(y: -Self.topBleed)
                .accessibilityHidden(true)

            IslandShape(cornerRadius: geometry.cornerRadius, minHeight: viewModel.notchSize.height)
                .fill(.black)
                .frame(width: geometry.size.width + IslandShape.earWidth * 2, height: geometry.size.height)
                .shadow(color: .black.opacity(geometry.isLifted ? 0.42 : 0), radius: 24, y: 18)

            content
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipShape(IslandBodyShape(cornerRadius: geometry.cornerRadius, minHeight: viewModel.notchSize.height))
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.state == .compact {
                        viewModel.expand()
                    }
                }

            ForEach(bubbles) { bubble in
                IslandBubbleView(bubble: bubble, viewModel: viewModel)
                    .offset(x: bubble.frame.midX)
                    .transition(.islandBubble(bubble))
            }
        }
        // On screens without a notch, slide down from the top edge when an
        // activity starts and back up past it when nothing is left. The slide
        // never overshoots: a bounce would pull the island's top edge off the
        // screen edge and show a sliver of desktop above it.
        .offset(y: viewModel.isTuckedAway ? -(viewModel.notchSize.height + Self.tuckClearance) : 0)
        .animation(.islandSlide, value: viewModel.isTuckedAway)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.island, value: geometry)
        .animation(.island, value: bubbles)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var content: some View {
        let nowPlaying = viewModel.nowPlaying
        let notch = viewModel.notchSize

        ZStack(alignment: .top) {
            switch viewModel.state {
            case .idle:
                EmptyView()
            case .compact:
                switch viewModel.primaryActivity {
                case .charging?:
                    ChargingCompactView(battery: viewModel.battery, notchSize: notch)
                        .transition(.islandContent)
                case .lowBattery?:
                    LowBatteryAlertView(battery: viewModel.battery, notchHeight: notch.height)
                        .transition(.islandContent)
                case .signIn?:
                    SignInCompactView(signIn: viewModel.signIn, notchSize: notch)
                        .transition(.islandContent)
                case .xcode?:
                    XcodeCompactView(xcode: viewModel.xcode, notchSize: notch)
                        .transition(.islandContent)
                case .terminal?:
                    TerminalCompactView(terminal: viewModel.terminal, notchSize: notch)
                        .transition(.islandContent)
                case .claudeCode?:
                    ClaudeCodeCompactView(claude: viewModel.claude, notchSize: notch)
                        .transition(.islandContent)
                case .github?:
                    GitHubCompactView(github: viewModel.github, notchSize: notch)
                        .transition(.islandContent)
                case .clipboard?:
                    ClipboardCompactView(clipboard: viewModel.clipboard, notchSize: notch)
                        .transition(.islandContent)
                case .calendar?:
                    CalendarCompactView(calendar: viewModel.calendar, notchSize: notch)
                        .transition(.islandContent)
                case .nowPlaying?:
                    NowPlayingCompactView(
                        nowPlaying: nowPlaying,
                        notchSize: notch,
                        routeSystemImage: viewModel.audioRoute.route?.systemImage
                    )
                    .transition(.islandContent)
                case nil:
                    EmptyView()
                }
            case .expanded:
                // Sign-in never opens, so anything but the player, a build, a
                // command, an agent, GitHub, the clipboard or the calendar
                // here is the battery's.
                switch viewModel.primaryActivity {
                case .nowPlaying?:
                    NowPlayingExpandedView(
                        nowPlaying: nowPlaying,
                        notchHeight: notch.height,
                        route: viewModel.audioRoute.route,
                        sourceName: viewModel.audioRoute.sourceName
                    )
                    .transition(.islandContent)
                case .xcode?:
                    XcodeExpandedView(xcode: viewModel.xcode, notchHeight: notch.height)
                        .transition(.islandContent)
                case .terminal?:
                    TerminalExpandedView(terminal: viewModel.terminal, notchHeight: notch.height)
                        .transition(.islandContent)
                case .claudeCode?:
                    ClaudeCodeExpandedView(claude: viewModel.claude, notchHeight: notch.height)
                        .transition(.islandContent)
                case .github?:
                    GitHubExpandedView(github: viewModel.github, notchHeight: notch.height)
                        .transition(.islandContent)
                case .clipboard?:
                    ClipboardExpandedView(clipboard: viewModel.clipboard, notchHeight: notch.height)
                        .transition(.islandContent)
                case .calendar?:
                    CalendarExpandedView(calendar: viewModel.calendar, notchHeight: notch.height)
                        .transition(.islandContent)
                default:
                    BatteryExpandedView(battery: viewModel.battery, notchHeight: notch.height)
                        .transition(.islandContent)
                }
            }
        }
    }
}

/// Activities waiting beside the island: the same black, hanging from the
/// top edge the same way, with each one's content centred in its share of
/// it. Clicking one opens that activity.
private struct IslandBubbleView: View {
    let bubble: IslandBubble
    let viewModel: NotchViewModel

    var body: some View {
        let size = bubble.frame.size

        ZStack(alignment: .top) {
            Rectangle()
                .fill(.black)
                .frame(width: size.width + IslandShape.earWidth * 2, height: IslandView.topBleed)
                .offset(y: -IslandView.topBleed)
                .accessibilityHidden(true)

            IslandShape(cornerRadius: NotchViewModel.compactCornerRadius, minHeight: viewModel.notchSize.height)
                .fill(.black)
                .frame(width: size.width + IslandShape.earWidth * 2, height: size.height)

            HStack(spacing: 0) {
                ForEach(bubble.segments, id: \.activity) { segment in
                    Group {
                        if !segment.overflow.isEmpty {
                            miniIcons(for: segment.overflow)
                                .transition(.islandContent)
                        } else {
                            content(for: segment.activity)
                                .transition(.islandContent)
                        }
                    }
                    .frame(width: size.width / CGFloat(bubble.segments.count), height: size.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.expand(segment.activity)
                    }
                    .transition(.islandContent)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// The ones that don't fit, each glyph shrunk and stacked over the next,
    /// the first on top. A black edge round each keeps them apart.
    private func miniIcons(for activities: [IslandActivity]) -> some View {
        let layout = BubbleLayout(notch: viewModel.notchSize)
        let size = (layout.artSize * Self.miniScale).rounded()

        return HStack(spacing: -size * Self.miniOverlap) {
            ForEach(Array(activities.enumerated()), id: \.element) { index, activity in
                content(for: activity)
                    .scaleEffect(size / layout.artSize)
                    .frame(width: size, height: size)
                    .background {
                        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                            .fill(.black)
                            .padding(-Self.miniEdge)
                    }
                    .zIndex(Double(activities.count - index))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(activities.count) more")
        .accessibilityAddTraits(.isButton)
    }

    /// Of a bubble's glyph: 16pt beside a 37pt notch.
    private static let miniScale: CGFloat = 0.7
    /// How much of each mini icon the next one hides.
    private static let miniOverlap: CGFloat = 0.38
    private static let miniEdge: CGFloat = 1.5

    @ViewBuilder
    private func content(for activity: IslandActivity) -> some View {
        switch activity {
        case .nowPlaying:
            NowPlayingMinimalView(
                nowPlaying: viewModel.nowPlaying,
                notchSize: viewModel.notchSize,
                routeSystemImage: bubble.isWide ? viewModel.audioRoute.route?.systemImage : nil
            )
        case .xcode:
            XcodeMinimalView(xcode: viewModel.xcode, notchSize: viewModel.notchSize)
        case .terminal:
            TerminalMinimalView(terminal: viewModel.terminal, notchSize: viewModel.notchSize)
        case .claudeCode:
            ClaudeCodeMinimalView(claude: viewModel.claude, notchSize: viewModel.notchSize)
        case .github:
            GitHubMinimalView(github: viewModel.github, notchSize: viewModel.notchSize)
        case .clipboard:
            ClipboardMinimalView(notchSize: viewModel.notchSize)
        case .calendar:
            CalendarMinimalView(calendar: viewModel.calendar, notchSize: viewModel.notchSize)
        case .signIn, .charging, .lowBattery:
            // A prompt always leads, and a battery alert shows alone.
            EmptyView()
        }
    }
}

extension AnyTransition {
    /// Incoming content waits for the silhouette to start growing, then fades
    /// in; outgoing content gets out of the way quickly.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    /// A bubble splits off the side of the island and springs out to its
    /// place, and goes back in the same way.
    static func islandBubble(_ bubble: IslandBubble) -> AnyTransition {
        let towardIsland = (bubble.frame.width + NotchViewModel.bubbleGap) * (bubble.frame.midX > 0 ? -1 : 1)
        let tucked = AnyTransition.offset(x: towardIsland)
            .combined(with: .scale(scale: 0.4, anchor: .top))
            .combined(with: .opacity)
        return .asymmetric(
            insertion: tucked.animation(.island),
            removal: tucked.animation(.easeIn(duration: 0.2))
        )
    }
}
