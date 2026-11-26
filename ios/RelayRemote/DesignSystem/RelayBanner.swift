import SwiftUI

/// An alert or status banner from the styles board ("Mac unreachable",
/// "Reconnecting" and so on): an outline icon, a title, a short message and
/// an optional secondary action, on a glass panel.
struct RelayBanner: Equatable, Identifiable {
    struct Action: Equatable {
        let title: String
        /// Compared by title only, so an unchanged banner does not re-animate.
        let perform: () -> Void

        static func == (lhs: Action, rhs: Action) -> Bool { lhs.title == rhs.title }
    }

    var id: String { title }
    let icon: LucideIcon
    let title: String
    var message: String?
    /// Error banners draw their icon in the error colour.
    var isError = false
    var action: Action?
}

struct RelayBannerView: View {
    let banner: RelayBanner

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LucideImage(banner.icon, size: 24)
                .foregroundStyle(banner.isError ? RelayColor.error : RelayColor.neutral10)
            VStack(alignment: .leading, spacing: 0) {
                Text(banner.title)
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral10)
                if let message = banner.message {
                    Text(message)
                        .relayTextStyle(.caption)
                        .foregroundStyle(RelayColor.neutral7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = banner.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.relaySecondary)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, banner.action == nil ? 16 : 12)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .relayGlass(.panel)
        .accessibilityElement(children: .contain)
    }
}

/// Where a floating banner sits: just below the status bar, 12 pt in from
/// each side, as in `25-agents-mac-unreachable.jpg`.
enum RelayBannerMetrics {
    static let top: CGFloat = 47
    static let sideMargin: CGFloat = 12
}

/// A banner a screen asks its container to float, for a screen whose container
/// draws something over it, such as the Workspace's ticket modal (RR-551). The
/// container shows it with `overlayPreferenceValue`, last, so it sits above.
struct FloatingBannerKey: PreferenceKey {
    static var defaultValue: RelayBanner? { nil }

    static func reduce(value: inout RelayBanner?, nextValue: () -> RelayBanner?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Hands `banner` to the container that floats banners (`FloatingBannerKey`).
    func floatingBanner(_ banner: RelayBanner?) -> some View {
        preference(key: FloatingBannerKey.self, value: banner)
    }

    /// Floats `banner` over this view, below the status bar. It never pushes
    /// content down. Apply it to a full-screen view.
    func relayBanner(_ banner: RelayBanner?) -> some View {
        overlay(alignment: .top) {
            ZStack {
                if let banner {
                    RelayBannerView(banner: banner)
                        .padding(.horizontal, RelayBannerMetrics.sideMargin)
                        .padding(.top, RelayBannerMetrics.top)
                        .transition(.relaySurface)
                }
            }
            .animation(RelayMotion.change, value: banner)
            .ignoresSafeArea(edges: .top)
        }
    }
}
