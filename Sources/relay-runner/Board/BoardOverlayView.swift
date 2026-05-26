import AppKit
import SwiftUI

/// Observable model driving the board view. The controller mutates `theme`
/// from a poll timer so the panel glow updates live as the particle field
/// changes (recording starts → red, playback starts → purple).
@Observable
final class BoardViewModel {
    var tickets: [Ticket] = []
    var theme: ParticleFieldRenderer.Theme?
    /// Live run state published by the daemon (runs.json), keyed by ticket id.
    /// Overlaid on ticket files for column placement and pill rendering — the
    /// ticket files themselves stay the source of truth for stable status.
    var runStates: [String: RunState] = [:]
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

    /// Hit-test `location` against the cached frames. Returns the column + the
    /// insertion index a drop at this point would land at, excluding the
    /// dragged ticket from the index calculation.
    func computeInsertTarget(at location: CGPoint, draggedId: String) -> DropTarget? {
        guard let (status, _) = columnFrames.first(where: { $0.value.contains(location) }) else {
            return nil
        }
        let columnTickets = tickets
            .filter { $0.status == status && $0.id != draggedId }
            .sorted { $0.order < $1.order }
        var index = columnTickets.count
        for (i, t) in columnTickets.enumerated() {
            if let frame = cardFrames[t.id], location.y < frame.midY {
                index = i
                break
            }
        }
        return DropTarget(status: status, index: index)
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
    var title: String
    var description: String
    var id: String { editorId }
}

/// State of an in-progress drag. `location` is in the board's named coordinate
/// space (the outer ZStack). `insertTarget` is recomputed on every change so
/// the destination column can render its drop indicator in the right slot.
struct DragState: Equatable {
    let ticket: Ticket
    var location: CGPoint
    var insertTarget: DropTarget?
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
        BoardColumnSpec(status: .ready,      title: "Ready"),
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
                HStack(alignment: .top, spacing: 12) {
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
                .padding(.top, 89)
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
                    .position(drag.location)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let draft = model.editing {
                TicketEditorModal(
                    draft: draft,
                    onCommit: { title, description in
                        var updated = draft
                        updated.title = title
                        updated.description = description
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
        model.tickets.filter { model.effectiveStatus(for: $0) == spec.status }
            .sorted { $0.order < $1.order }
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
                NewTicketButton(action: onCreate)
                    .help("New ticket in \(spec.title)")
            }
            .padding(.bottom, 4)

            ScrollView {
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
        .frame(width: 358, height: 633, alignment: .topLeading)
        .background(PillGlassBackground(cornerRadius: 16))
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
            radius: 20,
            x: 0,
            y: -6
        )
        .animation(.easeInOut(duration: 0.4), value: theme)
        .onTapGesture { /* swallow taps on the panel so they don't dismiss */ }
    }

    private static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
        switch theme {
        case .stt:
            return Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 0.15)
        case .tts:
            return Color(.sRGB, red: 40 / 255, green: 17 / 255, blue: 208 / 255, opacity: 0.15)
        case nil:
            return Color.black.opacity(0.45)
        }
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
                   activityRun: model.activityRun(for: ticket))
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
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }
}

/// Replicates the TranscriptionPill's "liquid glass" layer stack (TTS theme)
/// so columns and cards share the exact same visual language as the pill.
/// Mirrors values from `TranscriptionPill.init` — keep in sync if those change.
///
/// IMPORTANT: NSVisualEffectView's `.behindWindow` blending mode only reaches
/// the desktop when the effect view composites directly against the window —
/// wrapping it in a SwiftUI `ZStack` with a parent `clipShape` flattens the
/// stack into a backing buffer and the OS blur silently degrades to "just
/// transparency". So the structure here is deliberate:
///
///   - The blur is the receiver itself (a self-clipping NSVisualEffectView).
///   - Each tint / gradient / specular / border layer is applied via its own
///     `.overlay { ... }` so SwiftUI keeps them as sibling layers rather than
///     fusing them into one compositing group.
private struct PillGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        VisualEffectBlur(
            material: .underWindowBackground,
            blendingMode: .behindWindow,
            cornerRadius: cornerRadius
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.black.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(white: 0).opacity(0.10),
                            Color(white: 0.97).opacity(0.10),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay(alignment: .top) {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.0),
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.10), location: 0.0),
                            .init(color: Color.white.opacity(0.0),  location: 0.9),
                            .init(color: Color.white.opacity(0.0),  location: 1.0),
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.layer?.cornerRadius = cornerRadius
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
                } else if ticket.runId != nil {
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
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.35))
        )
        .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
        .opacity(ticket.canceled ? 0.45 : 1.0)
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
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// Live run-state pill driven by the daemon's runs-index. Mirrors
/// `AgentActivityBadge`'s glass capsule; the dot color separates states at a
/// glance (green running, amber stalled, red failed, blue awaiting-merge).
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
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
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
    let onCommit: (_ title: String, _ description: String) -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void

    @State private var title: String
    @State private var description: String
    @FocusState private var titleFocused: Bool

    init(
        draft: TicketDraft,
        onCommit: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.original = draft.original
        self.onCommit = onCommit
        self.onCancel = onCancel
        self.onDelete = onDelete
        self._title = State(initialValue: draft.title)
        self._description = State(initialValue: draft.description)
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
                            .background(
                                Circle().fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                            )
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
                            .fill(Color.black.opacity(0.30))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                    )

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 0.85))
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )
                        .contentShape(Capsule())
                        .pointingHandCursor()
                    Button("Save") { onCommit(title, description) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.white)
                        .background(
                            Capsule().fill(Color.white.opacity(0.20))
                        )
                        .contentShape(Capsule())
                        .pointingHandCursor()
                }
            }
            .padding(20)
            .frame(width: 520)
            .background(PillGlassBackground(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 10)
            .onTapGesture { /* swallow */ }
            .onAppear { titleFocused = true }
        }
    }
}
