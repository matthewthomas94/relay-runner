import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI

/// What the Workspace tab shows and how it asks for more: the live session's
/// feed, or fixed sample data for a screenshot.
struct WorkspaceFeed {
    var workspace: WorkspaceState?
    var isUnreachable = false
    var appUnavailable = false
    var refresh: () -> Void = {}
    var retryConnection: () -> Void = {}

    @MainActor
    init(session: RemoteSession?) {
        guard let session else {
            isUnreachable = true
            return
        }
        workspace = session.workspace
        isUnreachable = MacSessionStatus(session).phase == .unreachable
        appUnavailable = session.appUnavailable
        refresh = { session.requestWorkspace() }
        retryConnection = { session.retryNow() }
    }

    init(sample: WorkspaceState?, isUnreachable: Bool = false) {
        workspace = sample
        self.isUnreachable = isUnreachable
    }
}

/// What the tab body is, from the feed (RR-543).
enum WorkspacePhase: Equatable {
    case loading
    case list(WorkspaceListing)
    case error(String)

    static let appNotRunning = "Relay Runner isn’t running on your Mac."

    init(_ feed: WorkspaceFeed, project: String?) {
        if let workspace = feed.workspace {
            if let message = workspace.error {
                self = .error(message)
            } else {
                self = .list(WorkspaceListing(workspace, project: project))
            }
        } else if feed.appUnavailable && !feed.isUnreachable {
            self = .error(Self.appNotRunning)
        } else {
            self = .loading
        }
    }
}

/// Workspace (26): tickets by status with project tabs above the tab bar.
/// Read-only: a tapped ticket opens in the ticket modal (RR-551), where it can be read.
struct WorkspaceTabView: View {
    let model: AppModel
    var sample: WorkspaceFeed?

    @Environment(\.scenePhase) private var scenePhase

    private var feed: WorkspaceFeed { sample ?? WorkspaceFeed(session: model.session) }

    var body: some View {
        let feed = feed
        let phase = WorkspacePhase(feed, project: model.workspaceProject)
        VStack(spacing: 0) {
            content(phase, feed: feed)
            if case .list(let listing) = phase {
                ProjectTabStrip(tabs: listing.tabs, selection: Bindable(model).workspaceProject)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Drawn by `MainTabView`, above the ticket modal and its scrim.
        .floatingBanner(feed.isUnreachable ? Self.unreachableBanner(feed) : nil)
        .onAppear { if sample == nil { feed.refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, sample == nil { feed.refresh() }
        }
        .onChange(of: model.session?.state) { _, state in
            if state == .connected || state == .connectedToApp, sample == nil { feed.refresh() }
        }
    }

    @ViewBuilder
    private func content(_ phase: WorkspacePhase, feed: WorkspaceFeed) -> some View {
        switch phase {
        case .loading:
            if feed.isUnreachable {
                Spacer()
            } else {
                ProgressView().tint(RelayColor.neutral7).frame(maxHeight: .infinity)
            }
        case .error(let message):
            VStack(spacing: 12) {
                Text(message).relayTextStyle(.body).foregroundStyle(RelayColor.neutral7)
                Button("Retry") {
                    feed.retryConnection()
                    feed.refresh()
                }
                .buttonStyle(.relaySecondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .list(let listing):
            WorkspaceList(listing: listing, dimmed: feed.isUnreachable, open: { model.openTicket($0) }) {
                await refresh(feed)
            }
        }
    }

    /// Asks again and holds the pull-to-refresh spinner until the Mac answers
    /// or two seconds pass.
    private func refresh(_ feed: WorkspaceFeed) async {
        let before = model.session?.workspace
        feed.refresh()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if model.session?.workspace != before { return }
        }
    }

    private static func unreachableBanner(_ feed: WorkspaceFeed) -> RelayBanner {
        RelayBanner(icon: .wifiOff, title: "Mac unreachable", message: "Check Wi-Fi or Tailscale.", isError: true,
                    action: .init(title: "Retry") { feed.retryConnection() })
    }
}

/// The grouped ticket list, or "No open tickets".
private struct WorkspaceList: View {
    let listing: WorkspaceListing
    let dimmed: Bool
    let open: (WorkspaceTicket) -> Void
    let refresh: () async -> Void

    var body: some View {
        ScrollView {
            if listing.isEmpty {
                Text("No open tickets")
                    .relayTextStyle(.body).foregroundStyle(RelayColor.neutral7)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.groups, id: \.status) { group in
                        (Text(group.status.heading).font(RelayTextStyle.section.font).foregroundStyle(RelayColor.neutral10)
                            + Text("  \(group.tickets.count)").font(RelayTextStyle.body.font).foregroundStyle(RelayColor.neutral7))
                        VStack(spacing: 8) {
                            ForEach(group.tickets, id: \.id) { ticket in
                                Button { open(ticket) } label: {
                                    TicketRow(ticket: ticket, project: listing.projectName(of: ticket))
                                }
                                .buttonStyle(TicketRowButtonStyle())
                                .transition(.relayRise)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    }
                    if listing.truncated {
                        Text("Showing the first tickets only.")
                            .relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, RelayMetrics.screenMargin)
                .padding(.top, 72)
                // Tickets arriving, leaving or moving lanes animate instead of jumping.
                .animation(RelayMotion.move, value: listing.groups.map { $0.tickets.map(\.id) })
            }
        }
        .refreshable { await refresh() }
        .opacity(dimmed ? 0.3 : 1)
        .animation(RelayMotion.enter, value: dimmed)
        .accessibilityElement(children: .contain)
    }
}

/// A row that can be tapped: plain, and a little dimmer while pressed.
private struct TicketRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
            .relayPressed(configuration.isPressed)
    }
}

private struct TicketRow: View {
    let ticket: WorkspaceTicket
    let project: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text([ticket.id, project].compactMap { $0 }.joined(separator: " · "))
                .relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
            Text(ticket.title)
                .relayTextStyle(.cardTitle).foregroundStyle(RelayColor.neutral10)
                .fixedSize(horizontal: false, vertical: true)
            if let agent = ticket.agent {
                Text(agent.prefix(1).uppercased() + agent.dropFirst())
                    .relayTextStyle(.body).foregroundStyle(RelayColor.neutral10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(RelayColor.neutral3))
        .accessibilityElement(children: .combine)
    }
}

/// "All" then one tab per project, in the style of the agent tabs: plain
/// labels with a count, the selected one on an outlined pill.
private struct ProjectTabStrip: View {
    let tabs: [WorkspaceListing.ProjectTab]
    @Binding var selection: String?
    @Namespace private var pill

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tabs, id: \.id) { tab in
                    let selected = tab.id == selection
                    Button { withAnimation(RelayMotion.move) { selection = tab.id } } label: {
                        // Sized like the agent tabs (`AgentTabStrip`).
                        (Text(tab.name).foregroundStyle(selected ? RelayColor.neutral10 : RelayColor.neutral7)
                            + Text("  \(tab.count)").foregroundStyle(RelayColor.neutral7))
                            .relayTextStyle(AgentTabStrip.label)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .frame(height: AgentTabStrip.height)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(RelayColor.neutral3)
                                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(RelayColor.neutral5, lineWidth: 1))
                                        .matchedGeometryEffect(id: "pill", in: pill)
                                }
                            }
                            .animation(RelayMotion.enter, value: selected)
                    }
                    .buttonStyle(.relayPlain)
                    .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
        }
        .padding(.vertical, 12)
    }
}

extension WorkspaceFeed {
    /// Debug-only sample data matching `26-workspace.jpg`, for simulator
    /// screenshots; nil in release builds and for an unknown name.
    static func debugSample(_ name: String?) -> WorkspaceFeed? {
        #if DEBUG
        guard let name else { return nil }
        let projects = [WorkspaceProject(id: "p1", name: "relay-runner"), WorkspaceProject(id: "p2", name: "cad-engine"),
                        WorkspaceProject(id: "p3", name: "hidpress-web")]
        let tickets = [
            WorkspaceTicket(id: "RR-532", title: "Relay Remote: tab bar and Agents tab", status: .inProgress,
                            projectId: "p1", agent: "george"),
            WorkspaceTicket(id: "CE-88", title: "Fillet edges on imported STEP bodies", status: .inProgress,
                            projectId: "p2", agent: "sky"),
            WorkspaceTicket(id: "RR-533", title: "Workspace tab lists tickets by project", status: .queued,
                            projectId: "p1", agent: "george"),
            WorkspaceTicket(id: "RR-531", title: "Danger buttons use the glass secondary surface with a red label",
                            status: .backlog, projectId: "p1", agent: "george"),
        ]
        switch name {
        case "empty": return WorkspaceFeed(sample: WorkspaceState(projects: projects, tickets: []))
        case "error":
            return WorkspaceFeed(sample: WorkspaceState(projects: [], tickets: [],
                                                         error: "The Workspace is not available from the phone on this Mac yet."))
        case "unreachable": return WorkspaceFeed(sample: WorkspaceState(projects: projects, tickets: tickets), isUnreachable: true)
        case "truncated": return WorkspaceFeed(sample: WorkspaceState(projects: projects, tickets: tickets, truncated: true))
        default: return WorkspaceFeed(sample: WorkspaceState(projects: projects, tickets: tickets))
        }
        #else
        return nil
        #endif
    }
}
