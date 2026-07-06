import AppKit
import SwiftUI

enum BoardSurfaceLayout {
    static let horizontalPadding: CGFloat = 24
    static let columnSpacing: CGFloat = 10
    static let columnTopPadding: CGFloat = 78
    static let columnHeight: CGFloat = 633
}

enum BoardDarkSurfaceStyle {
    static let panelFillNSColor = NSColor(srgbRed: 9 / 255, green: 11 / 255, blue: 15 / 255, alpha: 1)
    static let contentFillNSColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let borderNSColor = NSColor(srgbRed: 17 / 255, green: 22 / 255, blue: 29 / 255, alpha: 1)

    static let panelFill = Color(nsColor: panelFillNSColor)
    static let contentFill = Color(nsColor: contentFillNSColor)
    static let border = Color(nsColor: borderNSColor)

    static let columnCornerRadius: CGFloat = 12
    static let pillCornerRadius: CGFloat = 16
    static let shadowOpacity: Double = 0.08
    static let shadowRadius: CGFloat = 4
    static let shadowYOffset: CGFloat = 2
}

/// Observable model driving the board view. The controller mutates `theme`
/// from a poll timer so live session state remains available to the board.
@Observable
final class BoardViewModel {
    var tickets: [Ticket] = [] {
        didSet { rebuildTicketCaches() }
    }
    var theme: ParticleFieldRenderer.Theme?
    /// Live run state published by the daemon (runs.json), keyed by ticket id.
    /// Overlaid on ticket files for column placement and pill rendering — the
    /// ticket files themselves stay the source of truth for stable status.
    var runStates: [String: RunState] = [:] {
        didSet { rebuildTicketCaches() }
    }
    /// When non-nil, the editor modal is rendered over the columns and the
    /// hosting panel takes key focus so text fields receive input. The
    /// controller listens for changes here and updates panel key-eligibility
    /// accordingly.
    var editing: TicketDraft?
    /// Non-nil while the user is mid-drag. The view renders a ghost card at
    /// `location` and dims the source card. Cleared on drop or cancel.
    var dragState: DragState?

    /// Geometry of each column, captured via `GeometryReader` and reported up
    /// via `ColumnFramesKey`. In the `.named("board")` coordinate space.
    var columnFrames: [Ticket.Status: CGRect] = [:]
    /// Per-card geometry in the same coordinate space — used to compute
    /// insert index during a drag.
    var cardFrames: [String: CGRect] = [:]

    @ObservationIgnored private var laneTickets: [Ticket.Status: [Ticket]] = [:]
    @ObservationIgnored private var ticketsByID: [String: Ticket] = [:]

    /// Column a ticket renders in: a live run can override the file's status
    /// (e.g. push a `ready` ticket into "In progress" while a worker grinds).
    /// Falls back to the ticket file's own status when no run overrides it.
    func effectiveStatus(for ticket: Ticket) -> Ticket.Status {
        runStates[ticket.id]?.placement(ticketStatus: ticket.status) ?? ticket.status
    }

    /// Status pill to render on a ticket card, or nil when no live run applies.
    func pill(for ticket: Ticket) -> RunPill? {
        runStates[ticket.id]?.pill(ticketStatus: ticket.status)
    }

    /// Live run backing a ticket's activity chip (RR-12), or nil when none.
    func activityRun(for ticket: Ticket) -> RunState? {
        runStates[ticket.id]
    }

    /// Tickets rendered in a lane, honoring live-run placement overrides
    /// rather than only the raw ticket-file status.
    func tickets(in status: Ticket.Status) -> [Ticket] {
        laneTickets[status] ?? []
    }

    func upsertTicket(_ ticket: Ticket) {
        if let index = tickets.firstIndex(where: { $0.id == ticket.id }) {
            tickets[index] = ticket
        } else {
            tickets.append(ticket)
        }
    }

    func upsertTickets(_ updatedTickets: [Ticket]) {
        for ticket in updatedTickets {
            upsertTicket(ticket)
        }
    }

    func removeTicket(id: String) {
        tickets.removeAll { $0.id == id }
    }

    /// Unsatisfied predecessors for a queued ticket. Missing predecessor files
    /// count as waiting so dependency-gated work does not silently dispatch.
    func waitingOn(for ticket: Ticket) -> [String] {
        guard effectiveStatus(for: ticket) == .ready, !ticket.dependsOn.isEmpty else {
            return []
        }
        return ticket.dependsOn.filter { dependencyID in
            guard let dependency = ticketsByID[dependencyID] else { return true }
            return dependency.status != .done
        }
    }

    /// Hit-test `location` against the cached frames. Returns the column + the
    /// insertion index a drop at this point would land at, excluding the
    /// dragged ticket from the index calculation.
    func computeInsertTarget(at location: CGPoint, draggedId: String) -> DropTarget? {
        guard let (status, _) = columnFrames.first(where: { $0.value.contains(location) }) else {
            return nil
        }
        let columnTickets = tickets(in: status)
            .filter { $0.id != draggedId }
        var index = columnTickets.count
        for (i, t) in columnTickets.enumerated() {
            if let frame = cardFrames[t.id], location.y < frame.midY {
                index = i
                break
            }
        }
        return DropTarget(status: status, index: index)
    }

    private func rebuildTicketCaches() {
        ticketsByID = Dictionary(uniqueKeysWithValues: tickets.map { ($0.id, $0) })

        var grouped: [Ticket.Status: [Ticket]] = [:]
        for ticket in tickets {
            grouped[effectiveStatus(for: ticket), default: []].append(ticket)
        }
        for status in Ticket.Status.allCases {
            grouped[status] = (grouped[status] ?? []).sorted(by: Ticket.boardOrder)
        }
        laneTickets = grouped
    }
}

/// Working copy of a ticket while the modal is open. Distinct from `Ticket`
/// (immutable file snapshot) so the form can mutate freely and the
/// controller decides on save/cancel whether to write back.
struct TicketDraft: Identifiable, Equatable {
    /// Stable identity for the editor sheet — uses the ticket id for existing
    /// tickets. Mostly cosmetic since the modal binds to `model.editing`.
    let editorId: String
    /// The ticket as it sits on disk right now. We diff against this on save.
    let original: Ticket
    /// True only for a ticket minted by the currently-open creation modal.
    /// Canceling that modal deletes the file instead of leaving an orphan.
    let isNew: Bool
    var title: String
    var status: Ticket.Status
    var priority: Ticket.Priority
    var description: String
    var acceptanceCriteria: String
    var id: String { editorId }
}

/// State of an in-progress drag. `location` is in the board's named coordinate
/// space (the outer ZStack). `insertTarget` is recomputed on every change so
/// the destination column can render its drop indicator in the right slot.
struct DragState: Equatable {
    let ticket: Ticket
    var location: CGPoint
    var cardCenterOffset: CGSize
    var insertTarget: DropTarget?

    static func cardCenterOffset(cardFrame: CGRect?, startLocation: CGPoint) -> CGSize {
        guard let cardFrame,
              cardFrame.width > 0,
              cardFrame.height > 0 else {
            return .zero
        }
        return CGSize(
            width: cardFrame.midX - startLocation.x,
            height: cardFrame.midY - startLocation.y
        )
    }

    var cardCenter: CGPoint {
        CGPoint(
            x: location.x + cardCenterOffset.width,
            y: location.y + cardCenterOffset.height
        )
    }
}

struct DropTarget: Equatable {
    let status: Ticket.Status
    let index: Int
}

// MARK: - Preference keys for collecting frames

private struct ColumnFramesKey: PreferenceKey {
    typealias Value = [Ticket.Status: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

private struct CardFramesKey: PreferenceKey {
    typealias Value = [String: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - Cursor helpers

/// View modifier that swaps the mouse cursor to a pointing hand while
/// hovering. Used on buttons inside the panel because plain SwiftUI buttons
/// don't pick up the system pointing-hand cursor automatically (and inside a
/// non-key NSPanel, the default arrow lingers from the TextEditor / cards
/// underneath, producing the wrong icon over buttons).
private struct PointingHandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Open-hand cursor for draggable cards. Becomes the closed-hand "grab"
/// cursor while a drag is in progress — communicates "this can be picked up".
private struct GrabCursor: ViewModifier {
    let dragging: Bool
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                (dragging ? NSCursor.closedHand : NSCursor.openHand).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private extension View {
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
    func grabCursor(dragging: Bool) -> some View { modifier(GrabCursor(dragging: dragging)) }
}

// MARK: - Top-level view

struct BoardOverlayView: View {
    @Bindable var model: BoardViewModel
    let onDismiss: () -> Void
    /// Drag-drop handler. Called when a ticket is dropped on a column (or on
    /// a position within a column). The controller writes to disk and re-scans.
    let onDrop: (_ ticketId: String, _ status: Ticket.Status, _ insertIndex: Int) -> Void
    /// "+" button per column. Mints a new ticket in that column and opens
    /// the editor for it.
    let onCreate: (_ status: Ticket.Status) -> Void
    /// Open the editor for an existing ticket.
    let onEdit: (_ ticket: Ticket) -> Void
    /// Modal commit. The controller persists the draft to disk.
    let onCommit: (_ draft: TicketDraft) -> Void
    /// Modal cancel. Clears `model.editing` without writing.
    let onCancel: () -> Void
    /// Delete the ticket currently open in the modal.
    let onDelete: (_ ticket: Ticket) -> Void

    private let columns: [BoardColumnSpec] = [
        BoardColumnSpec(status: .backlog,    title: "Backlog"),
        BoardColumnSpec(status: .ready,      title: "Queued"),
        BoardColumnSpec(status: .inProgress, title: "In progress"),
        BoardColumnSpec(status: .done,       title: "Done"),
    ]

    var body: some View {
        ZStack {
            // Background: clicking dismisses the board *only when no modal is
            // open*. When the editor is up, the same click cancels the modal
            // instead — keeps the board state stable while editing.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.editing != nil {
                        onCancel()
                    } else {
                        onDismiss()
                    }
                }

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                    ForEach(columns) { spec in
                        BoardColumnPanel(
                            model: model,
                            spec: spec,
                            theme: model.theme,
                            onCreate: { onCreate(spec.status) },
                            onEdit: onEdit,
                            onDrop: onDrop
                        )
                    }
                }
                .padding(.horizontal, BoardSurfaceLayout.horizontalPadding)
                .padding(.top, BoardSurfaceLayout.columnTopPadding)
                .frame(maxWidth: .infinity, alignment: .top)
                Spacer(minLength: 0)
            }

            // Drag ghost — lives inside the panel's coordinate space so it's
            // rendered above the columns AND on top of every other window the
            // panel is on top of. Solves the "preview behind the columns" bug
            // we had with SwiftUI's `.draggable` (whose system drag-image
            // window sits at a lower NSWindow level than `.screenSaver`).
            if let drag = model.dragState {
                TicketCard(ticket: drag.ticket)
                    .frame(width: 310)
                    .opacity(0.95)
                    .scaleEffect(1.03)
                    .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 14)
                    .position(drag.cardCenter)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let draft = model.editing {
                TicketEditorModal(
                    draft: draft,
                    onCommit: { title, status, priority, description, acceptanceCriteria in
                        var updated = draft
                        updated.title = title
                        updated.description = description
                        updated.status = status
                        updated.priority = priority
                        updated.acceptanceCriteria = acceptanceCriteria
                        onCommit(updated)
                    },
                    onCancel: onCancel,
                    onDelete: { onDelete(draft.original) }
                )
                // .id ties the @State inside the modal to the specific draft —
                // opening a different ticket while one was open replaces the
                // state instead of keeping the old fields.
                .id(draft.editorId)
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: "board")
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.15), value: model.editing != nil)
        .onPreferenceChange(ColumnFramesKey.self) { model.columnFrames = $0 }
        .onPreferenceChange(CardFramesKey.self) { model.cardFrames = $0 }
    }
}

struct BoardColumnSpec: Identifiable {
    let status: Ticket.Status
    let title: String
    var id: String { status.rawValue }
}

private struct BoardColumnPanel: View {
    @Bindable var model: BoardViewModel
    let spec: BoardColumnSpec
    let theme: ParticleFieldRenderer.Theme?
    let onCreate: () -> Void
    let onEdit: (Ticket) -> Void
    let onDrop: (String, Ticket.Status, Int) -> Void

    private var tickets: [Ticket] {
        // Placement honors the live-run override (a worker can pull a `ready`
        // ticket into "In progress") rather than the raw ticket-file status.
        model.tickets(in: spec.status)
    }

    /// Index inside this column where the active drag would land, or `nil`
    /// when no drag is targeting this column.
    private var hoverIndex: Int? {
        guard let target = model.dragState?.insertTarget, target.status == spec.status else {
            return nil
        }
        return target.index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text(spec.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0))
                Spacer(minLength: 0)
                Text("\(tickets.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.65))
                    .monospacedDigit()
                NewTicketButton(action: onCreate)
                    .help("New ticket in \(spec.title)")
            }
            .padding(.bottom, 4)

            BoardColumnTicketScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(tickets.enumerated()), id: \.element.id) { idx, ticket in
                        VStack(spacing: 0) {
                            DropIndicator(visible: hoverIndex == idx)
                            DraggableTicketCard(
                                model: model,
                                ticket: ticket,
                                onEdit: { onEdit(ticket) },
                                onDrop: onDrop
                            )
                        }
                    }
                    // Tail indicator + a generous drop region for "append" or
                    // "drop into empty column".
                    DropIndicator(visible: hoverIndex == tickets.count)
                    Color.clear
                        .frame(minHeight: tickets.isEmpty ? 120 : 40)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
        .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
        // Report frame for drag hit-testing. Placed after the background so
        // the geometry matches the visible panel rect.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ColumnFramesKey.self,
                    value: [spec.status: proxy.frame(in: .named("board"))]
                )
            }
        )
        .shadow(
            color: BoardColumnPanel.shadowColor(for: theme),
            radius: BoardDarkSurfaceStyle.shadowRadius,
            x: 0,
            y: BoardDarkSurfaceStyle.shadowYOffset
        )
        .animation(.easeInOut(duration: 0.4), value: theme)
        .onTapGesture { /* swallow taps on the panel so they don't dismiss */ }
    }

    private static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
        switch theme {
        case .stt, .tts, nil:
            return Color.black.opacity(BoardDarkSurfaceStyle.shadowOpacity)
        }
    }
}

private struct BoardColumnTicketScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 28)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }
}

/// Thin white bar that shows where a drop would land. Visible only when the
/// drag's hover index matches the slot this indicator sits in.
private struct DropIndicator: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(visible ? 0.55 : 0))
            .frame(height: 3)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .animation(.easeOut(duration: 0.10), value: visible)
    }
}

/// Wraps `TicketCard` with the drag gesture, source-fade behavior, and frame
/// reporting. The actual drag visualization (ghost following the cursor) is
/// rendered at the top level — this view only manages the source side.
private struct DraggableTicketCard: View {
    @Bindable var model: BoardViewModel
    let ticket: Ticket
    let onEdit: () -> Void
    let onDrop: (String, Ticket.Status, Int) -> Void

    private var isBeingDragged: Bool {
        model.dragState?.ticket.id == ticket.id
    }

    var body: some View {
        TicketCard(ticket: ticket, pill: model.pill(for: ticket),
                   activityRun: model.activityRun(for: ticket),
                   waitingOn: model.waitingOn(for: ticket))
            .opacity(isBeingDragged ? 0.25 : 1.0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CardFramesKey.self,
                        value: [ticket.id: proxy.frame(in: .named("board"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .grabCursor(dragging: isBeingDragged)
            .onTapGesture { onEdit() }
            .gesture(
                // minimumDistance: 5 lets a click+release fire `onTapGesture`
                // (no drag), while a press+move starts the drag.
                DragGesture(minimumDistance: 5, coordinateSpace: .named("board"))
                    .onChanged { value in
                        if model.dragState == nil {
                            model.dragState = DragState(
                                ticket: ticket,
                                location: value.location,
                                cardCenterOffset: DragState.cardCenterOffset(
                                    cardFrame: model.cardFrames[ticket.id],
                                    startLocation: value.startLocation
                                ),
                                insertTarget: nil
                            )
                        } else {
                            model.dragState?.location = value.location
                        }
                        model.dragState?.insertTarget = model.computeInsertTarget(
                            at: value.location,
                            draggedId: ticket.id
                        )
                    }
                    .onEnded { _ in
                        if let target = model.dragState?.insertTarget {
                            onDrop(ticket.id, target.status, target.index)
                        }
                        model.dragState = nil
                    }
            )
    }
}

private struct NewTicketButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
                .frame(width: 22, height: 22)
                .background(BoardDarkCircleBackground())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

struct BoardDarkSurfaceBackground: View {
    let cornerRadius: CGFloat
    var fill: Color = BoardDarkSurfaceStyle.panelFill

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(BoardDarkSurfaceStyle.border, lineWidth: 1)
            )
    }
}

struct BoardDarkCapsuleBackground: View {
    var fill: Color = BoardDarkSurfaceStyle.contentFill
    var stroke: Color = BoardDarkSurfaceStyle.border

    var body: some View {
        Capsule()
            .fill(fill)
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
    }
}

struct BoardDarkCircleBackground: View {
    var fill: Color = BoardDarkSurfaceStyle.contentFill
    var stroke: Color = BoardDarkSurfaceStyle.border

    var body: some View {
        Circle()
            .fill(fill)
            .overlay(Circle().stroke(stroke, lineWidth: 1))
    }
}

private struct TicketCard: View {
    let ticket: Ticket
    /// Live-run pill from the daemon's runs-index. Takes precedence over the
    /// ticket-file `run_id` "Building" badge when present.
    var pill: RunPill? = nil
    /// Live run backing the activity chip (RR-12). The chip is subordinate to
    /// the pill — it adds "what the agent is doing now", not the primary state.
    var activityRun: RunState? = nil
    var waitingOn: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text(ticket.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let pill {
                    RunStatusPill(pill: pill)
                } else if !waitingOn.isEmpty {
                    DependencyWaitingBadge()
                } else if ticket.status == .inProgress && ticket.runId != nil {
                    AgentActivityBadge(activity: .building)
                }
            }
            // Live activity chip. Re-evaluated on a 1s timeline so a worker that
            // goes silent flips to "Idle" without needing a runs.json change.
            if let activityRun, activityRun.isActive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let text = activityRun.activityChip(now: context.date) {
                        ActivityChip(text: text)
                    }
                }
            }
            if !waitingOn.isEmpty {
                Text("Waiting on \(waitingOn.joined(separator: ", "))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(.sRGB, red: 245 / 255, green: 180 / 255, blue: 40 / 255, opacity: 0.95))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help("Waiting on \(waitingOn.joined(separator: ", "))")
            }
            if let description = ticket.description {
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.65))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            BoardDarkSurfaceBackground(
                cornerRadius: BoardDarkSurfaceStyle.pillCornerRadius,
                fill: BoardDarkSurfaceStyle.contentFill
            )
        )
        .shadow(
            color: Color.black.opacity(BoardDarkSurfaceStyle.shadowOpacity),
            radius: BoardDarkSurfaceStyle.shadowRadius,
            x: 0,
            y: BoardDarkSurfaceStyle.shadowYOffset
        )
        .opacity(ticket.canceled ? 0.45 : 1.0)
    }
}

private struct DependencyWaitingBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(.sRGB, red: 245 / 255, green: 180 / 255, blue: 40 / 255, opacity: 1.0))
                .frame(width: 6, height: 6)
                .opacity(0.9)
            Text("Waiting")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(BoardDarkCapsuleBackground())
        .fixedSize()
    }
}

/// Subordinate one-line chip describing the worker's current action (RR-12):
/// smaller and lower-contrast than the status pill. Truncates with an ellipsis;
/// the full text is available on hover and to VoiceOver.
private struct ActivityChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .regular))
            .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.5))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
            .accessibilityLabel("Agent activity: \(text)")
    }
}

/// "Building"/"Testing" pill shown on tickets currently being worked by a
/// sub-agent.
private struct AgentActivityBadge: View {
    enum Activity {
        case building
        case testing

        var label: String {
            switch self {
            case .building: return "Building"
            case .testing:  return "Testing"
            }
        }

        var dotColor: Color {
            switch self {
            case .building:
                return Color(.sRGB, red: 198 / 255, green: 191 / 255, blue: 249 / 255, opacity: 1.0)
            case .testing:
                return Color(.sRGB, red: 242 / 255, green: 223 / 255, blue: 12 / 255, opacity: 1.0)
            }
        }
    }

    let activity: Activity

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(activity.dotColor)
                .frame(width: 6, height: 6)
                .opacity(0.9)
            Text(activity.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(BoardDarkCapsuleBackground())
    }
}

/// Live run-state pill driven by the daemon's runs-index. The dot color
/// separates states at a glance (green running, amber stalled, red failed,
/// blue awaiting-merge).
private struct RunStatusPill: View {
    let pill: RunPill

    private var label: String {
        switch pill {
        case .running:       return "Running"
        case .stalled:       return "Stalled"
        case .failed:        return "Failed"
        case .awaitingMerge: return "Awaiting merge"
        }
    }

    private var dotColor: Color {
        switch pill {
        case .running:       return Color(.sRGB, red: 52 / 255,  green: 211 / 255, blue: 153 / 255, opacity: 1.0)
        case .stalled:       return Color(.sRGB, red: 245 / 255, green: 180 / 255, blue: 40 / 255,  opacity: 1.0)
        case .failed:        return Color(.sRGB, red: 244 / 255, green: 60 / 255,  blue: 9 / 255,   opacity: 1.0)
        case .awaitingMerge: return Color(.sRGB, red: 96 / 255,  green: 165 / 255, blue: 250 / 255, opacity: 1.0)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .opacity(0.9)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(BoardDarkCapsuleBackground())
        .fixedSize()
    }
}

// MARK: - Editor modal

/// Centered modal for editing a ticket's title and description.
///
/// Holds the in-flight title/description as private `@State` rather than
/// binding back to `model.editing`. This sidesteps a SwiftUI teardown bug:
/// when the modal dismisses, `@FocusState` flipping false fires one last
/// write through the title field's binding chain, which — if that chain
/// terminates in `model.editing` — re-populates the optional and the modal
/// re-mounts immediately. With `@State` the working copy lives and dies
/// with the modal; the parent only learns about changes on Save.
private struct TicketEditorModal: View {
    let original: Ticket
    let onCommit: (
        _ title: String,
        _ status: Ticket.Status,
        _ priority: Ticket.Priority,
        _ description: String,
        _ acceptanceCriteria: String
    ) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var title: String
    @State private var status: Ticket.Status
    @State private var priority: Ticket.Priority
    @State private var description: String
    @State private var acceptanceCriteria: String
    @FocusState private var titleFocused: Bool

    init(
        draft: TicketDraft,
        onCommit: @escaping (
            _ title: String,
            _ status: Ticket.Status,
            _ priority: Ticket.Priority,
            _ description: String,
            _ acceptanceCriteria: String
        ) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.original = draft.original
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onDelete = onDelete
        self._title = State(initialValue: draft.title)
        self._status = State(initialValue: draft.status)
        self._priority = State(initialValue: draft.priority)
        self._description = State(initialValue: draft.description)
        self._acceptanceCriteria = State(initialValue: draft.acceptanceCriteria)
    }

    var body: some View {
        ZStack {
            // Scrim. Tap to cancel.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Text(original.id)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.55))
                    Spacer(minLength: 0)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 0.90))
                            .frame(width: 24, height: 24)
                            .background(BoardDarkCircleBackground())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Delete ticket")
                }

                TextField("Title", text: $title, axis: .vertical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .lineLimit(1...3)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.55))
                            .textCase(.uppercase)
                        Picker("Status", selection: $status) {
                            ForEach(Ticket.Status.allCases, id: \.rawValue) { status in
                                Text(status.rawValue.displayLabel).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Priority")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.55))
                            .textCase(.uppercase)
                        Picker("Priority", selection: $priority) {
                            ForEach(Ticket.Priority.allCases, id: \.rawValue) { priority in
                                Text(priority.rawValue.displayLabel).tag(priority)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    Spacer(minLength: 0)
                }

                Divider()
                    .background(Color.white.opacity(0.12))

                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.55))
                    .textCase(.uppercase)

                TextEditor(text: $description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.90))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 160, maxHeight: 280)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(BoardDarkSurfaceStyle.contentFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
                    )

                Text("Acceptance criteria")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.55))
                    .textCase(.uppercase)

                TextEditor(text: $acceptanceCriteria)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.90))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 220)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(BoardDarkSurfaceStyle.contentFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
                        .background(BoardDarkCapsuleBackground())
                        .contentShape(Capsule())
                        .pointingHandCursor()
                    Button("Save") { onCommit(title, status, priority, description, acceptanceCriteria) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.white)
                        .background(BoardDarkCapsuleBackground(fill: BoardDarkSurfaceStyle.panelFill))
                        .contentShape(Capsule())
                        .pointingHandCursor()
                }
            }
            .padding(20)
            .frame(width: 520)
            .background(BoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.pillCornerRadius))
            .shadow(
                color: Color.black.opacity(BoardDarkSurfaceStyle.shadowOpacity),
                radius: BoardDarkSurfaceStyle.shadowRadius,
                x: 0,
                y: BoardDarkSurfaceStyle.shadowYOffset
            )
            .onTapGesture { /* swallow */ }
            .onAppear { titleFocused = true }
        }
    }
}
