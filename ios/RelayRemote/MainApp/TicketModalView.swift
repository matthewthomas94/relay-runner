import RelayRemoteKit
import RelayRemoteProtocol
import SwiftUI

/// What the ticket modal reads when it is not the Mac's: fixed sample data for
/// a debug screenshot (`--ticket-sample=<name>`, see `LaunchOptions`).
struct TicketSample {
    var row: WorkspaceTicket
    var workspace: WorkspaceState
    var reply: WorkspaceTicketDetail?
    var unsupported = false
    var isUnreachable = false
}

/// The Workspace tab's ticket modal (RR-551): the tapped ticket, header from
/// its row at once, then its text rendered from Markdown. Read-only.
struct TicketModalView: View {
    let model: AppModel
    var sample: TicketSample?

    @State private var timedOut = false
    @Environment(\.scenePhase) private var scenePhase

    /// How long the body may wait before the modal says the Mac is not answering.
    static let answerTimeout: Duration = .seconds(12)

    private var session: RemoteSession? { sample == nil ? model.session : nil }

    private var reading: WorkspaceTicketReading? {
        guard let row = sample?.row ?? model.shownTicket else { return nil }
        if let sample {
            return WorkspaceTicketReading(row: row, workspace: sample.workspace, reply: sample.reply,
                                          unsupported: sample.unsupported)
        }
        let key = SessionCore.ticketKey(projectID: row.projectId, ticketID: row.id)
        return WorkspaceTicketReading(row: row, workspace: session?.workspace, reply: session?.workspaceTickets[key],
                                      unsupported: session?.ticketUnsupported ?? false, timedOut: timedOut)
    }

    private var isUnreachable: Bool {
        if let sample { return sample.isUnreachable }
        return session.map { MacSessionStatus($0).phase == .unreachable } ?? true
    }

    var body: some View {
        RelayModal(isPresented: model.isTicketOpen, onClose: { model.closeTicket() },
                   refresh: sample == nil ? refresh : nil) {
            if let reading { TicketHeader(reading: reading) }
        } content: {
            if let reading {
                TicketBody(state: reading.body, dimmed: isUnreachable, retry: retry)
            }
        }
        .task(id: model.isTicketOpen ? model.ticketRequests : -1) {
            guard model.isTicketOpen, sample == nil, let row = model.shownTicket else { return }
            timedOut = false
            session?.requestWorkspaceTicket(projectID: row.projectId, ticketID: row.id)
            try? await Task.sleep(for: Self.answerTimeout)
            if !Task.isCancelled { timedOut = true }
        }
        // A connection that comes back, or the app returning, asks again; the text on screen stays.
        .onChange(of: session?.state) { _, state in
            if model.isTicketOpen, state == .connected || state == .connectedToApp { model.refreshTicket() }
        }
        .onChange(of: scenePhase) { _, phase in
            if model.isTicketOpen, phase == .active { model.refreshTicket() }
        }
    }

    /// Pull to refresh: asks again and holds the spinner until the Mac answers or two seconds pass.
    private func refresh() async {
        let before = reading?.body
        model.refreshTicket()
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            if reading?.body != before { return }
        }
    }

    private func retry() {
        session?.retryNow()
        model.refreshTicket()
    }
}

/// The ticket id and project on one small line, the title, and the status in
/// words with the owning agent: no page title, no pills or lights.
private struct TicketHeader: View {
    let reading: WorkspaceTicketReading

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reading.eyebrow).relayScaledTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
            Text(reading.title)
                .relayScaledTextStyle(.cardTitle).foregroundStyle(RelayColor.neutral10)
                .fixedSize(horizontal: false, vertical: true)
            Text(reading.statusLine).relayScaledTextStyle(.body).foregroundStyle(RelayColor.neutral10)
        }
    }
}

/// The scrolling part: loading, the rendered text, or one line and Retry.
private struct TicketBody: View {
    let state: WorkspaceTicketReading.Body
    let dimmed: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch state {
            case .loading:
                ProgressView().tint(RelayColor.neutral7).frame(maxWidth: .infinity).padding(.vertical, 24)
            case .text(let markdown, let truncated):
                MarkdownView(blocks: MarkdownBlocks.parse(markdown))
                if truncated {
                    Text("Open on your Mac to read the rest.")
                        .relayScaledTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                }
            case .error(let message):
                Text(message).relayScaledTextStyle(.body).foregroundStyle(RelayColor.neutral7)
                Button("Retry", action: retry).buttonStyle(.relaySecondary)
            case .unsupported:
                Text(WorkspaceTicketReading.unsupportedMessage)
                    .relayScaledTextStyle(.body).foregroundStyle(RelayColor.neutral7)
            }
        }
        .padding(.top, 4)
        .opacity(dimmed ? 0.3 : 1)
    }
}

// MARK: - Markdown

/// The blocks of a ticket body in the design system's type: Bai Jamjuree,
/// white on the panel. Headings, paragraphs, lists with read-only task boxes,
/// and code blocks that scroll sideways. Links open in the system browser.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(styled(text, style: Self.headingStyle(level)))
                        .relayScaledTextStyle(Self.headingStyle(level))
                        .padding(.top, level <= 2 ? 8 : 0)
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let text):
                    Text(styled(text, style: .body)).relayScaledTextStyle(.body)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            ListItemRow(item: item, text: styled(item.text, style: .body))
                        }
                    }
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).relayScaledTextStyle(.caption).foregroundStyle(RelayColor.neutral10)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(12)
                    }
                    .background(RoundedRectangle(cornerRadius: RelayMetrics.buttonRadius, style: .continuous)
                        .fill(RelayColor.neutral4))
                }
            }
        }
        .foregroundStyle(RelayColor.neutral10)
        .tint(RelayColor.neutral10)
        .environment(\.openURL, OpenURLAction { Self.opensInTheBrowser($0) ? .systemAction : .discarded })
    }

    static func headingStyle(_ level: Int) -> RelayTextStyle {
        switch level {
        case 1: return .titleL
        case 2: return .cardTitle
        default: return .section
        }
    }

    /// Only web and mail links leave the app.
    static func opensInTheBrowser(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Fonts and colours for the inline runs: bold is SemiBold, inline code
    /// sits on the secondary surface, links are underlined.
    private func styled(_ text: AttributedString, style: RelayTextStyle) -> AttributedString {
        var result = text
        let regular = style.font(scaledBy: scale)
        let semibold = RelayTextStyle(weight: .semiBold, size: style.size, lineHeight: style.lineHeight).font(scaledBy: scale)
        for run in text.runs {
            let range = run.range
            let intent = run.inlinePresentationIntent ?? []
            var font = style.weight == .semiBold || intent.contains(.stronglyEmphasized) ? semibold : regular
            if intent.contains(.emphasized) { font = font.italic() }
            result[range].font = font
            if intent.contains(.code) {
                // Text would set inline code in the system monospace face; the design system has one family.
                result[range].inlinePresentationIntent = nil
                result[range].backgroundColor = RelayColor.neutral4
            }
            if run.link != nil {
                result[range].underlineStyle = .single
                result[range].foregroundColor = RelayColor.neutral10
            }
        }
        return result
    }
}

private struct ListItemRow: View {
    let item: MarkdownListItem
    let text: AttributedString

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 20 * scale, alignment: .leading)
            Text(text).relayScaledTextStyle(.body)
        }
        .padding(.leading, CGFloat(item.depth) * 16)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .bullet:
            Text("•").relayScaledTextStyle(.body).foregroundStyle(RelayColor.neutral7)
        case .number(let number):
            Text("\(number).").relayScaledTextStyle(.body).foregroundStyle(RelayColor.neutral7)
        case .task(let checked):
            ZStack {
                LucideImage(.square, size: 20 * scale)
                if checked { LucideImage(.check, size: 14 * scale) }
            }
            .foregroundStyle(checked ? RelayColor.neutral10 : RelayColor.neutral7)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 * scale }
            .accessibilityLabel(checked ? "Done" : "Not done")
        }
    }
}

// MARK: - Debug samples

extension TicketSample {
    /// Debug-only sample for `--ticket-sample=<name>`, matching a row of the
    /// `--workspace-sample` list; nil in release builds and for an unknown name.
    static func debugSample(_ name: String?, unreachable: Bool = false) -> TicketSample? {
        #if DEBUG
        guard let name else { return nil }
        let row = WorkspaceTicket(id: "RR-532", title: "Relay Remote: tab bar and Agents tab", status: .inProgress,
                                  projectId: "p1", agent: "george")
        var workspace = WorkspaceState(
            projects: [WorkspaceProject(id: "p1", name: "relay-runner")], tickets: [row])
        func reply(_ markdown: String? = nil, truncated: Bool? = nil, error: String? = nil) -> WorkspaceTicketDetail {
            WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-532", title: row.title, status: .inProgress,
                                  agent: "george", markdown: markdown, truncated: truncated, error: error)
        }
        var sample = TicketSample(row: row, workspace: workspace, reply: nil, isUnreachable: unreachable)
        switch name {
        case "loading": break
        case "error": sample.reply = WorkspaceTicketDetail(projectId: "p1", ticketId: "RR-532", error: "That ticket no longer exists.")
        case "unsupported": sample.unsupported = true
        case "long": sample.reply = reply(sampleMarkdown + "\n" + sampleMarkdown)
        case "truncated": sample.reply = reply(sampleMarkdown, truncated: true)
        case "done":
            workspace.tickets = []
            sample.workspace = workspace
            sample.reply = reply("## Description\n\nShipped.\n")
        default: sample.reply = reply(sampleMarkdown)
        }
        return sample
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Two headings, a paragraph, a bulleted list, a task list, inline code, a code block and a link.
    static let sampleMarkdown = """
    ## Description

    On the **Workspace** tab, tapping a ticket opens it here. The text keeps its *emphasis*, `inline code` and a [link to the docs](https://example.com/docs).

    ### Acceptance criteria

    - The tab bar stays reachable
    - The agent tabs scroll sideways
    - Each ticket opens in a modal

    - [x] Header filled from the row
    - [ ] Body rendered from Markdown

    ```swift
    let tickets = workspace.tickets.filter { $0.status == .inProgress }
    ```
    """
    #endif
}
