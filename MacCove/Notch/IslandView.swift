import SwiftUI

/// The island itself. The black silhouette springs between sizes while the
/// content for each state cross-fades in on top at a fixed width, so text
/// never reflows mid-animation.
struct IslandView: View {
    let viewModel: NotchViewModel

    /// Extra distance past the top edge when tucked away, enough to clear
    /// the few points the island grows on hover.
    private static let tuckClearance: CGFloat = 12
    private static let topBleed: CGFloat = 8

    var body: some View {
        let geometry = viewModel.geometry

        ZStack(alignment: .top) {
            // Black above the island's top edge, normally off screen. If the
            // island ever sits a pixel or two low (rounding mid-slide on a
            // scaled display), this fills the gap instead of the wallpaper.
            Rectangle()
                .fill(.black)
                .frame(width: geometry.size.width + IslandShape.earWidth * 2, height: Self.topBleed)
                .offset(y: -Self.topBleed)
                .accessibilityHidden(true)

            IslandShape(cornerRadius: geometry.cornerRadius)
                .fill(.black)
                .frame(width: geometry.size.width + IslandShape.earWidth * 2, height: geometry.size.height)
                .shadow(color: .black.opacity(geometry.isLifted ? 0.42 : 0), radius: 24, y: 18)

            content
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .clipShape(
                    UnevenRoundedRectangle(
                        bottomLeadingRadius: geometry.cornerRadius,
                        bottomTrailingRadius: geometry.cornerRadius
                    )
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    if viewModel.state == .compact {
                        viewModel.expand()
                    }
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
                NowPlayingCompactView(
                    nowPlaying: nowPlaying,
                    notchSize: notch,
                    routeSystemImage: viewModel.audioRoute.route?.systemImage
                )
                .transition(.islandContent)
            case .expanded:
                NowPlayingExpandedView(
                    nowPlaying: nowPlaying,
                    notchHeight: notch.height,
                    route: viewModel.audioRoute.route,
                    sourceName: viewModel.audioRoute.sourceName
                )
                .transition(.islandContent)
            }
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
}
