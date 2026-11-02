import SwiftUI

/// The island itself. The black silhouette springs between sizes while the
/// content for each state cross-fades in on top at a fixed width, so text
/// never reflows mid-animation.
struct IslandView: View {
    let viewModel: NotchViewModel

    var body: some View {
        let geometry = viewModel.geometry

        ZStack(alignment: .top) {
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
        .opacity(viewModel.isHidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.island, value: geometry)
        .animation(.easeOut(duration: 0.2), value: viewModel.isHidden)
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
                NowPlayingCompactView(nowPlaying: nowPlaying, notchSize: notch)
                    .transition(.islandContent)
            case .expanded:
                NowPlayingExpandedView(nowPlaying: nowPlaying, notchHeight: notch.height)
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
