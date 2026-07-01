import AppKit
import SwiftUI

enum ProgramBoardBackdropStyle {
    static let backdropOpacity: Double = 0.96
    static let bottomCornerRadius: CGFloat = 14
    static let bottomPadding: CGFloat = 24
    static let glassBlendingMode = NSVisualEffectView.BlendingMode.withinWindow

    static var backdropHeight: CGFloat {
        BoardSurfaceLayout.columnTopPadding + BoardSurfaceLayout.columnHeight + bottomPadding
    }
}

struct ProgramBoardOverlayView: View {
    @Bindable var model: ProgramBoardViewModel
    let onDismiss: () -> Void
    let onRefresh: () -> Void
    let onStartSession: () -> Void
    let onEndSession: () -> Void
    let onOpenProject: (String) -> Void
    let onCreateStart: (ProgramBoardLane) -> Void
    let onCreateCommit: (ProgramBoardCreateRequest) -> Void
    let onCreateCancel: () -> Void
    let onEditStart: (ProgramTicketDetail) -> Void
    let onEditCommit: (ProgramBoardEditRequest) -> Void
    let onEditCancel: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            ProgramBoardBackdropShape(cornerRadius: ProgramBoardBackdropStyle.bottomCornerRadius)
                .fill(Color.black.opacity(ProgramBoardBackdropStyle.backdropOpacity))
                .frame(maxWidth: .infinity)
                .frame(height: ProgramBoardBackdropStyle.backdropHeight)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.editing != nil {
                        onEditCancel()
                    } else if model.creating != nil {
                        onCreateCancel()
                    } else {
                        onDismiss()
                    }
                }

            VStack(spacing: 0) {
                ProgramBoardContent(
                    model: model,
                    onRefresh: onRefresh,
                    onStartSession: onStartSession,
                    onEndSession: onEndSession,
                    onDismiss: onDismiss,
                    onOpenProject: onOpenProject,
                    onCreateStart: onCreateStart,
                    onEditStart: onEditStart,
                    onDelete: onDelete,
                    onDrop: onDrop
                )
                .padding(.top, BoardSurfaceLayout.columnTopPadding)

                Spacer(minLength: 0)
            }

            ProgramDragPreviewLayer(model: model)

            if let draft = model.creating {
                ProgramTicketCreateModal(
                    draft: draft,
                    projects: model.projectTargets,
                    makeRequest: { selectedProjectPath, title, description in
                        model.createRequest(
                            selectedProjectPath: selectedProjectPath,
                            title: title,
                            description: description
                        )
                    },
                    onCommit: onCreateCommit,
                    onCancel: onCreateCancel
                )
                .id("\(draft.lane.id)-\(draft.selectedProjectPath ?? "all")")
                .transition(.opacity)
            }

            if let draft = model.editing {
                ProgramTicketEditModal(
                    draft: draft,
                    makeRequest: { title, status, priority, description, acceptanceCriteria in
                        model.editRequest(
                            title: title,
                            status: status,
                            priority: priority,
                            description: description,
                            acceptanceCriteria: acceptanceCriteria
                        )
                    },
                    onCommit: onEditCommit,
                    onCancel: onEditCancel,
                    onDelete: onDelete
                )
                .id(draft.id)
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: "programBoard")
        .ignoresSafeArea()
        .onPreferenceChange(ProgramColumnFramesKey.self) { model.columnFrames = $0 }
        .onPreferenceChange(ProgramCardFramesKey.self) { model.cardFrames = $0 }
    }
}

private struct ProgramBoardBackdropShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct ProgramColumnFramesKey: PreferenceKey {
    typealias Value = [ProgramBoardLane: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ProgramCardFramesKey: PreferenceKey {
    typealias Value = [String: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ProgramDragPreviewLayer: View {
    @Bindable var model: ProgramBoardViewModel

    var body: some View {
        if let drag = model.dragPreview {
            ProgramWorkCard(
                item: drag.item,
                lane: drag.sourceLane,
                isSelected: false,
                showsProjectContext: true,
                onSelect: {},
                onEdit: {}
            )
            .frame(width: 246)
            .opacity(0.95)
            .scaleEffect(1.03)
            .shadow(color: Color.black.opacity(0.55), radius: 22, x: 0, y: 14)
            .position(drag.cardCenter)
            .allowsHitTesting(false)
            .transaction { transaction in
                transaction.animation = nil
            }
        }
    }
}

private struct ProgramGrabCursor: ViewModifier {
    let dragging: Bool
    let enabled: Bool

    func body(content: Content) -> some View {
        content.onHover { hovering in
            guard enabled else { return }
            if hovering {
                (dragging ? NSCursor.closedHand : NSCursor.openHand).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct ProgramButtonCursor: ViewModifier {
    let enabled: Bool
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    guard !isPushed else { return }
                    (enabled ? NSCursor.pointingHand : NSCursor.arrow).push()
                    isPushed = true
                } else if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onDisappear {
                guard isPushed else { return }
                NSCursor.pop()
                isPushed = false
            }
    }
}

private extension View {
    func programGrabCursor(dragging: Bool, enabled: Bool) -> some View {
        modifier(ProgramGrabCursor(dragging: dragging, enabled: enabled))
    }

    func programButtonCursor(enabled: Bool = true) -> some View {
        modifier(ProgramButtonCursor(enabled: enabled))
    }
}

enum ProgramBoardContentPresentation: Equatable {
    case board
    case noRegisteredProjects
    case empty

    static func resolve(
        hasSnapshot: Bool,
        hasRegisteredProjects: Bool
    ) -> ProgramBoardContentPresentation {
        guard hasSnapshot else { return .empty }
        return hasRegisteredProjects ? .board : .noRegisteredProjects
    }
}

private struct ProgramBoardContent: View {
    @Bindable var model: ProgramBoardViewModel
    let onRefresh: () -> Void
    let onStartSession: () -> Void
    let onEndSession: () -> Void
    let onDismiss: () -> Void
    let onOpenProject: (String) -> Void
    let onCreateStart: (ProgramBoardLane) -> Void
    let onEditStart: (ProgramTicketDetail) -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    var body: some View {
        switch ProgramBoardContentPresentation.resolve(
            hasSnapshot: model.snapshot != nil,
            hasRegisteredProjects: model.snapshot?.hasRegisteredProjects ?? false
        ) {
        case .board:
            if let snapshot = model.snapshot {
                ZStack(alignment: .top) {
                    HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                        ProgramOverviewColumn(
                            snapshot: snapshot,
                            selectedProjectPath: model.selectedProjectPath,
                            selectedScopeTitle: model.selectedScopeTitle,
                            errorMessage: model.errorMessage,
                            reloadState: model.reloadState,
                            theme: model.theme,
                            hasActiveSession: model.hasActiveSession,
                            onSelectAll: model.selectAllProjects,
                            onSelectProject: model.selectProject,
                            onRefresh: onRefresh,
                            onStartSession: onStartSession,
                            onEndSession: onEndSession,
                            onDismiss: onDismiss
                        )
                        ForEach(ProgramBoardLane.allCases) { lane in
                            ProgramWorkColumnPanel(
                                model: model,
                                lane: lane,
                                showsProjectContext: model.isAllSelected,
                                theme: model.theme,
                                canCreate: !model.projectTargets.isEmpty,
                                onCreate: { onCreateStart(lane) },
                                onEdit: { item in onEditStart(ProgramTicketDetail.load(item: item)) },
                                onDrop: onDrop
                            )
                        }
                    }
                    .padding(.horizontal, BoardSurfaceLayout.horizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .top)

                    if let detail = model.selectedTicketDetail {
                        ProgramTicketDetailPanel(
                            detail: detail,
                            theme: model.theme,
                            onClose: model.clearSelectedTicket,
                            onEdit: { onEditStart(detail) },
                            onDelete: onDelete,
                            onOpenProject: onOpenProject
                        )
                        .padding(.top, 18)
                        .zIndex(1)
                    }
                }
            }
        case .noRegisteredProjects:
            if let snapshot = model.snapshot {
                ProgramStatePanel(
                    title: "No registered projects",
                    detail: model.errorMessage ?? snapshot.summary.message,
                    reloadState: model.reloadState,
                    theme: model.theme,
                    onRefresh: onRefresh,
                    onDismiss: onDismiss
                )
            }
        case .empty:
            emptySurface
        }
    }

    private var emptySurface: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgramOverviewColumn: View {
    let snapshot: ProgramDashboardSnapshot
    let selectedProjectPath: String?
    let selectedScopeTitle: String
    let errorMessage: String?
    let reloadState: ProgramBoardReloadState
    let theme: ParticleFieldRenderer.Theme?
    let hasActiveSession: Bool
    let onSelectAll: () -> Void
    let onSelectProject: (String) -> Void
    let onRefresh: () -> Void
    let onStartSession: () -> Void
    let onEndSession: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                reloadState: reloadState,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )

            if let errorMessage {
                ProgramErrorStrip(message: errorMessage)
            }

            ProgramMetricGrid(snapshot: snapshot)

            ProgramProjectFilterHeader(
                count: snapshot.projects.count,
                selectedScopeTitle: selectedScopeTitle,
                isAllSelected: selectedProjectPath == nil,
                hasActiveSession: hasActiveSession,
                onStartSession: onStartSession,
                onEndSession: onEndSession,
                onSelectAll: onSelectAll
            )

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.projects) { item in
                        ProgramProjectCard(
                            item: item,
                            isSelected: selectedProjectPath == item.project?.path,
                            onSelect: {
                                if let path = item.project?.path {
                                    onSelectProject(path)
                                }
                            }
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .programColumnChrome(theme: theme)
    }
}

private struct ProgramBoardTitleBar: View {
    let reloadState: ProgramBoardReloadState
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Program Board")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                    ProgramReloadButton(state: reloadState, action: onRefresh)
                }
                Text(reloadState.statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(reloadState.isFailure ? ProgramBoardStyle.red : ProgramBoardStyle.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ProgramIconButton(systemName: "xmark", help: "Close Program Board", action: onDismiss)
        }
    }
}

private struct ProgramMetricGrid: View {
    let snapshot: ProgramDashboardSnapshot

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ProgramMetricTile(label: "Projects", value: "\(snapshot.projectCount)")
            ProgramMetricTile(label: "Backlog", value: "\(snapshot.backlogWork.items.count)")
            ProgramMetricTile(label: "Queued", value: "\(snapshot.readyWork.items.count)")
            ProgramMetricTile(label: "Progress", value: "\(snapshot.inProgressWork.items.count)")
            ProgramMetricTile(label: "Done", value: "\(snapshot.doneWork.items.count)")
            ProgramMetricTile(
                label: "Awaiting merge",
                value: "\(snapshot.awaitingMerge.items.count)",
                help: "Agent work that has finished and is waiting to be merged back into its project."
            )
        }
    }
}

private struct ProgramMetricTile: View {
    let label: String
    let value: String
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProgramCardBackground(cornerRadius: 12))
        .help(help ?? label)
    }
}

private struct ProgramProjectFilterHeader: View {
    let count: Int
    let selectedScopeTitle: String
    let isAllSelected: Bool
    let hasActiveSession: Bool
    let onStartSession: () -> Void
    let onEndSession: () -> Void
    let onSelectAll: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Projects")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .monospacedDigit()
                }
                Text(selectedScopeTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 6) {
                if hasActiveSession {
                    ProgramEndSessionButton(action: onEndSession)
                } else {
                    ProgramStartSessionButton(action: onStartSession)
                }
                Button(action: onSelectAll) {
                    Text("All")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isAllSelected ? ProgramBoardStyle.primaryText : ProgramBoardStyle.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(isAllSelected ? 0.16 : 0.07))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(isAllSelected ? 0.25 : 0.10), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help("Show tickets from all projects")
            }
        }
    }
}

private struct ProgramProjectCard: View {
    let item: ProgramStatusItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.project?.name ?? "Unknown project")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !item.providers.isEmpty {
                        Text(item.providers.joined(separator: ", "))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                    }
                }

                Text(item.project?.path ?? "unknown")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProjectBoardOverview(item: item)

                if let stale = item.staleRuns, stale > 0 {
                    Text("\(stale) stale")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(1)
                }

                if !item.providerHealth.isEmpty {
                    Text(item.providerHealth.joined(separator: "  "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(isSelected ? 0.28 : 0), lineWidth: 0.75)
            )
            .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(item.project?.path == nil)
        .help("Show tickets for \(item.project?.name ?? "this project")")
    }
}

private struct ProjectBoardOverview: View {
    let item: ProgramStatusItem

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ProjectCount(label: "Backlog", value: item.backlogTickets ?? item.openTickets)
            ProjectCount(label: "Queued", value: item.readyTickets)
            ProjectCount(label: "In progress", value: item.inProgressTickets ?? item.activeRuns)
            ProjectCount(label: "Done", value: item.doneTickets)
        }
        .help("Project board overview")
    }
}

private struct ProjectCount: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
            Text("\(value ?? 0)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
    }
}

private struct ProgramWorkColumnPanel: View {
    @Bindable var model: ProgramBoardViewModel
    let lane: ProgramBoardLane
    let showsProjectContext: Bool
    let theme: ParticleFieldRenderer.Theme?
    let canCreate: Bool
    let onCreate: () -> Void
    let onEdit: (ProgramStatusItem) -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    private var items: [ProgramStatusItem] {
        model.ticketItems(in: lane)
    }

    private var activeTarget: ProgramBoardDropTarget? {
        guard let target = model.dragTarget, target.lane == lane else {
            return nil
        }
        return target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text(lane.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .monospacedDigit()
                if canCreate {
                    ProgramIconButton(
                        systemName: "plus",
                        help: "New \(lane.title.lowercased()) ticket",
                        action: onCreate
                    )
                }
            }
            .padding(.bottom, 4)

            ProgramColumnTicketScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ProgramDropIndicator(target: activeTarget)
                    if items.isEmpty {
                        ProgramColumnEmpty(text: lane.emptyText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(items) { item in
                                DraggableProgramWorkCard(
                                    model: model,
                                    item: item,
                                    lane: lane,
                                    isSelected: model.selectedTicketDetail?.id == item.id,
                                    showsProjectContext: showsProjectContext,
                                    onSelect: { model.selectTicket(item) },
                                    onEdit: { onEdit(item) },
                                    onDrop: onDrop
                                )
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .programColumnChrome(theme: theme)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ProgramColumnFramesKey.self,
                    value: [lane: proxy.frame(in: .named("programBoard"))]
                )
            }
        )
    }
}

private struct ProgramColumnTicketScrollView<Content: View>: View {
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

private struct ProgramDropIndicator: View {
    let target: ProgramBoardDropTarget?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(indicatorColor)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.10), value: target)
            .help(target?.isValid == false ? "Cannot drop this ticket here" : "Drop ticket here")
    }

    private var indicatorColor: Color {
        guard let target else { return Color.clear }
        return target.isValid ? Color.white.opacity(0.55) : ProgramBoardStyle.red.opacity(0.75)
    }
}

private struct DraggableProgramWorkCard: View {
    @Bindable var model: ProgramBoardViewModel
    let item: ProgramStatusItem
    let lane: ProgramBoardLane
    let isSelected: Bool
    let showsProjectContext: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    private var isBeingDragged: Bool {
        model.dragItemID == item.id
    }

    private var canDrag: Bool {
        item.isProgramBoardDraggable
    }

    var body: some View {
        ProgramWorkCard(
            item: item,
            lane: lane,
            isSelected: isSelected,
            showsProjectContext: showsProjectContext,
            onSelect: onSelect,
            onEdit: onEdit
        )
            .opacity(isBeingDragged ? 0.25 : 1.0)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ProgramCardFramesKey.self,
                        value: [item.id: proxy.frame(in: .named("programBoard"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .programGrabCursor(dragging: isBeingDragged, enabled: canDrag)
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("programBoard"))
                    .onChanged { value in
                        guard canDrag else { return }
                        let target = model.dropTarget(
                            at: value.location,
                            for: item,
                            sourceLane: lane
                        )
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            if model.dragItemID == nil {
                                model.beginDrag(
                                    item: item,
                                    sourceLane: lane,
                                    location: value.location,
                                    cardCenterOffset: cardCenterOffset(startLocation: value.startLocation),
                                    target: target
                                )
                            } else {
                                model.updateDrag(location: value.location, target: target)
                            }
                        }
                    }
                    .onEnded { _ in
                        guard canDrag else { return }
                        if let target = model.dragTarget, target.isValid {
                            onDrop(item, lane, target.lane)
                        }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            model.endDrag()
                        }
                    }
            )
            .help(canDrag ? "Drag ticket to another lane" : "This ticket cannot be dragged while a worker owns its state")
    }

    private func cardCenterOffset(startLocation: CGPoint) -> CGSize {
        ProgramBoardDragState.cardCenterOffset(
            cardFrame: model.cardFrames[item.id],
            startLocation: startLocation
        )
    }
}

private struct ProgramWorkCard: View {
    let item: ProgramStatusItem
    let lane: ProgramBoardLane
    let isSelected: Bool
    let showsProjectContext: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(projectName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showsProjectContext ? ProgramBoardStyle.secondaryText : ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(ticketID)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)

                ProgramIconButton(
                    systemName: "square.and.pencil",
                    help: editHelp,
                    action: onEdit
                )
                .disabled(!canEdit)
                .opacity(canEdit ? 1.0 : 0.45)
            }

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            let badges = stateBadges
            if !badges.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    ForEach(badges, id: \.self) { label in
                        ProgramInlineBadge(label: label)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let dependencyText {
                Text(dependencyText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.blockedBy.isEmpty ? ProgramBoardStyle.secondaryText : ProgramBoardStyle.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let statusText {
                Text(statusText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let lastError = item.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(ProgramBoardStyle.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ProgramCardBackground(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(isSelected ? 0.28 : 0), lineWidth: 0.75)
        )
        .shadow(color: Color.black.opacity(0.40), radius: 8, x: 0, y: 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(cardHelp)
    }

    private var projectName: String {
        cleaned(item.project?.name) ?? "Unknown project"
    }

    private var ticketID: String {
        cleaned(item.ticketID) ?? "No ticket"
    }

    private var title: String {
        cleaned(item.title) ?? "Untitled work"
    }

    private var stateBadges: [String] {
        var labels: [String] = []
        if item.isAwaitingMerge {
            labels.append("Awaiting merge")
        } else if item.hasActiveWorker {
            labels.append("Active worker")
        }
        if !item.blockedBy.isEmpty {
            labels.append("Waiting")
        }
        return labels
    }

    private var dependencyText: String? {
        var parts: [String] = []
        if !item.blockedBy.isEmpty {
            parts.append("waiting on \(item.blockedBy.joined(separator: ", "))")
        }
        if !item.dependsOn.isEmpty {
            parts.append("depends on \(item.dependsOn.joined(separator: ", "))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var statusText: String? {
        var parts: [String] = []
        if let state = visibleStateLabel {
            parts.append(state)
        }
        if let runID = cleaned(item.runID) {
            parts.append("run \(runID)")
        }
        if let branch = cleaned(item.branch) {
            parts.append(branch)
        }
        if let provider = cleaned(item.provider) {
            parts.append(provider)
        }
        if let activity = cleaned(item.activity) {
            parts.append(activity)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var visibleStateLabel: String? {
        for state in [item.runState, item.ticketState, item.status] {
            guard let state = cleaned(state) else { continue }
            let key = state.programStateKey
            guard !lane.redundantStateKeys.contains(key) else { continue }
            guard key != "active", key != "awaiting_merge" else { continue }
            return state.displayLabel
        }
        return nil
    }

    private var cardHelp: String {
        var parts = [projectName, ticketID, title]
        if let path = cleaned(item.project?.path) {
            parts.append(path)
        }
        return parts.joined(separator: " - ")
    }

    private var canEdit: Bool {
        ProgramTicketIdentity(item: item) != nil
    }

    private var editHelp: String {
        canEdit ? "Edit ticket" : "Ticket identity is unavailable"
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ProgramTicketDetailPanel: View {
    let detail: ProgramTicketDetail
    let theme: ParticleFieldRenderer.Theme?
    let onClose: () -> Void
    let onEdit: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void
    let onOpenProject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.identity?.ticketID ?? "No ticket")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                        if detail.item.isAwaitingMerge {
                            ProgramInlineBadge(label: "Awaiting merge")
                        }
                    }
                    Text(detail.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(2)
                    Text(detail.projectName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                    if let projectPath = detail.identity?.projectPath {
                        Text(projectPath)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Close ticket details", action: onClose)
            }

            HStack(alignment: .center, spacing: 8) {
                ProgramDetailActionButton(
                    systemName: "square.and.pencil",
                    title: "Edit",
                    disabled: detail.ticket == nil,
                    help: detail.ticket == nil ? "Ticket file is unavailable" : "Edit child ticket"
                ) {
                    onEdit()
                }
                ProgramDetailActionButton(
                    systemName: "trash",
                    title: "Delete",
                    disabled: deleteRequest == nil,
                    help: deleteRequest == nil ? "Ticket file is unavailable" : "Delete child ticket",
                    destructive: true
                ) {
                    if let deleteRequest {
                        onDelete(deleteRequest)
                    }
                }
                ProgramDetailActionButton(
                    systemName: "rectangle.stack",
                    title: "Copy ID",
                    disabled: detail.identity == nil,
                    help: "Copy child ticket id"
                ) {
                    copyToPasteboard(detail.identity?.ticketID)
                }
                ProgramDetailActionButton(
                    systemName: "doc.on.doc",
                    title: "Copy Path",
                    disabled: detail.ticketPath == nil,
                    help: "Copy child ticket path"
                ) {
                    copyToPasteboard(detail.ticketPath)
                }
                ProgramDetailActionButton(
                    systemName: "folder",
                    title: "Reveal",
                    disabled: detail.ticket == nil,
                    help: detail.ticket == nil ? "Ticket file is unavailable" : "Reveal child ticket file"
                ) {
                    revealTicket()
                }
                ProgramDetailActionButton(
                    systemName: "rectangle.grid.2x2",
                    title: "Open Board",
                    disabled: detail.identity?.projectPath == nil,
                    help: "Open the owning project board"
                ) {
                    if let projectPath = detail.identity?.projectPath {
                        onOpenProject(projectPath)
                    }
                }
            }

            if let unavailableMessage = detail.unavailableMessage {
                ProgramDetailNotice(message: unavailableMessage)
            }

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ProgramDetailMetadata(rows: metadataRows)
                    ProgramDetailSection(
                        title: "Description",
                        text: detail.description ?? "No description in the ticket file."
                    )
                    ProgramDetailSection(
                        title: "Acceptance criteria",
                        text: detail.acceptanceCriteria ?? "No acceptance criteria in the ticket file."
                    )
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 560, height: 633, alignment: .topLeading)
        .background(ProgramBoardGlassBackground(cornerRadius: 16))
        .shadow(color: ProgramBoardColumnChrome.shadowColor(for: theme), radius: 22, x: 0, y: -6)
        .contentShape(Rectangle())
        .onTapGesture { }
    }

    private var deleteRequest: ProgramBoardDeleteRequest? {
        guard let identity = detail.identity,
              detail.ticket != nil else {
            return nil
        }
        return ProgramBoardDeleteRequest(
            repoPath: identity.projectPath,
            ticketID: identity.ticketID
        )
    }

    private var metadataRows: [ProgramDetailRow] {
        var rows: [ProgramDetailRow] = []
        append("Status", detail.item.status ?? detail.ticket?.status.rawValue, to: &rows)
        append("Priority", detail.item.priority ?? detail.ticket?.priority.rawValue, to: &rows)
        append("Ticket state", detail.item.ticketState, to: &rows)
        append("Run state", detail.item.runState, to: &rows)
        append("Run ID", detail.item.runID.map { "run \($0)" }, to: &rows, prettify: false)
        append("Branch", detail.item.branch, to: &rows, prettify: false)
        append("Provider", detail.item.provider, to: &rows, prettify: false)
        append("Worker model", detail.item.workerModel, to: &rows, prettify: false)
        append("Worker effort", detail.item.workerEffort, to: &rows)
        append("Sizing rationale", detail.item.workerSizingRationale, to: &rows, prettify: false)
        append("Provider notes", detail.item.workerProviderNotes, to: &rows, prettify: false)
        if !detail.item.dependsOn.isEmpty {
            rows.append(ProgramDetailRow(label: "Depends on", value: detail.item.dependsOn.joined(separator: ", ")))
        } else if let ticket = detail.ticket, !ticket.dependsOn.isEmpty {
            rows.append(ProgramDetailRow(label: "Depends on", value: ticket.dependsOn.joined(separator: ", ")))
        }
        if !detail.item.blockedBy.isEmpty {
            rows.append(ProgramDetailRow(label: "Waiting on", value: detail.item.blockedBy.joined(separator: ", ")))
        }
        append("Activity", detail.item.activity, to: &rows, prettify: false)
        append("Last error", detail.item.lastError, to: &rows, prettify: false)
        if detail.ticket?.canceled == true {
            rows.append(ProgramDetailRow(label: "Canceled", value: "Yes"))
        }
        return rows
    }

    private func append(
        _ label: String,
        _ value: String?,
        to rows: inout [ProgramDetailRow],
        prettify: Bool = true
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        rows.append(ProgramDetailRow(label: label, value: prettify ? value.displayLabel : value))
    }

    private func copyToPasteboard(_ value: String?) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealTicket() {
        guard let ticketPath = detail.ticketPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ticketPath)])
    }
}

private struct ProgramDetailRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct ProgramDetailMetadata: View {
    let rows: [ProgramDetailRow]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        if !rows.isEmpty {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                        Text(row.value)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct ProgramDetailSection: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .lineLimit(1)
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgramDetailNotice: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.red)
            .lineLimit(3)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 12))
    }
}

private struct ProgramDetailActionButton: View {
    let systemName: String
    let title: String
    let disabled: Bool
    let help: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(disabled ? 0.04 : 0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(disabled ? 0.06 : 0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .programButtonCursor(enabled: !disabled)
        .help(help)
    }

    private var foregroundStyle: Color {
        if disabled {
            return ProgramBoardStyle.primaryText.opacity(0.45)
        }
        return destructive ? ProgramBoardStyle.red : ProgramBoardStyle.primaryText.opacity(0.95)
    }
}

private struct ProgramTicketEditModal: View {
    let draft: ProgramBoardEditDraft
    let makeRequest: (
        _ title: String,
        _ status: Ticket.Status,
        _ priority: Ticket.Priority,
        _ description: String,
        _ acceptanceCriteria: String
    ) -> ProgramBoardEditRequest?
    let onCommit: (ProgramBoardEditRequest) -> Void
    let onCancel: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void

    @State private var title: String
    @State private var status: Ticket.Status
    @State private var priority: Ticket.Priority
    @State private var description: String
    @State private var acceptanceCriteria: String
    @FocusState private var titleFocused: Bool

    init(
        draft: ProgramBoardEditDraft,
        makeRequest: @escaping (
            _ title: String,
            _ status: Ticket.Status,
            _ priority: Ticket.Priority,
            _ description: String,
            _ acceptanceCriteria: String
        ) -> ProgramBoardEditRequest?,
        onCommit: @escaping (ProgramBoardEditRequest) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: @escaping (ProgramBoardDeleteRequest) -> Void
    ) {
        self.draft = draft
        self.makeRequest = makeRequest
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
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Text(draft.identity.ticketID)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ProgramIconButton(
                        systemName: "trash",
                        help: "Delete ticket",
                        iconColor: ProgramBoardStyle.red
                    ) {
                        onDelete(deleteRequest)
                    }
                    ProgramIconButton(systemName: "xmark", help: "Cancel edit", action: onCancel)
                }

                Text(draft.identity.projectPath)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                TextField("Title", text: $title, axis: .vertical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .lineLimit(1...3)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .textCase(.uppercase)
                        Picker("Status", selection: $status) {
                            ForEach(Ticket.Status.allCases, id: \.rawValue) { status in
                                Text(status.rawValue.displayLabel).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Priority")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
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

                ProgramEditTextArea(
                    title: "Description",
                    text: $description,
                    minHeight: 130,
                    maxHeight: 220
                )

                ProgramEditTextArea(
                    title: "Acceptance criteria",
                    text: $acceptanceCriteria,
                    minHeight: 130,
                    maxHeight: 220
                )

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .foregroundStyle(ProgramBoardStyle.primaryText.opacity(0.85))
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                        .programButtonCursor()
                    Button("Save") {
                        if let request = currentRequest {
                            onCommit(request)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .disabled(currentRequest == nil)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.white.opacity(currentRequest == nil ? 0.45 : 1.0))
                    .background(Capsule().fill(Color.white.opacity(currentRequest == nil ? 0.08 : 0.20)))
                    .contentShape(Capsule())
                    .programButtonCursor(enabled: currentRequest != nil)
                }
            }
            .padding(20)
            .frame(width: 560)
            .background(ProgramBoardGlassBackground(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 10)
            .onTapGesture { }
            .onAppear { titleFocused = true }
        }
    }

    private var currentRequest: ProgramBoardEditRequest? {
        makeRequest(title, status, priority, description, acceptanceCriteria)
    }

    private var deleteRequest: ProgramBoardDeleteRequest {
        ProgramBoardDeleteRequest(
            repoPath: draft.identity.projectPath,
            ticketID: draft.identity.ticketID
        )
    }
}

private struct ProgramEditTextArea: View {
    let title: String
    @Binding var text: String
    let minHeight: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .textCase(.uppercase)

            TextEditor(text: $text)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.30))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        }
    }
}

private struct ProgramTicketCreateModal: View {
    let draft: ProgramBoardCreateDraft
    let projects: [ProgramBoardProjectTarget]
    let makeRequest: (_ selectedProjectPath: String?, _ title: String, _ description: String) -> ProgramBoardCreateRequest?
    let onCommit: (ProgramBoardCreateRequest) -> Void
    let onCancel: () -> Void

    @State private var selectedProjectPath: String?
    @State private var title: String
    @State private var description: String
    @FocusState private var titleFocused: Bool

    init(
        draft: ProgramBoardCreateDraft,
        projects: [ProgramBoardProjectTarget],
        makeRequest: @escaping (_ selectedProjectPath: String?, _ title: String, _ description: String) -> ProgramBoardCreateRequest?,
        onCommit: @escaping (ProgramBoardCreateRequest) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.projects = projects
        self.makeRequest = makeRequest
        self.onCommit = onCommit
        self.onCancel = onCancel
        self._selectedProjectPath = State(initialValue: draft.selectedProjectPath)
        self._title = State(initialValue: "")
        self._description = State(initialValue: "")
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Text(draft.lane.title)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    ProgramIconButton(systemName: "xmark", help: "Cancel new ticket", action: onCancel)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Project")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .textCase(.uppercase)
                    Picker("Project", selection: $selectedProjectPath) {
                        Text("Select project").tag(nil as String?)
                        ForEach(projects) { project in
                            Text(project.name).tag(project.path as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()

                    Text(selectedProject?.path ?? "Select project")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TextField("Title", text: $title, axis: .vertical)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .lineLimit(1...3)

                Divider()
                    .background(Color.white.opacity(0.12))

                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .textCase(.uppercase)

                TextEditor(text: $description)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
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
                        .foregroundStyle(ProgramBoardStyle.primaryText.opacity(0.85))
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                        .programButtonCursor()
                    Button("Save") {
                        if let request = makeRequest(selectedProjectPath, title, description) {
                            onCommit(request)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.plain)
                    .disabled(makeRequest(selectedProjectPath, title, description) == nil)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.white.opacity(canSave ? 1.0 : 0.45))
                    .background(Capsule().fill(Color.white.opacity(canSave ? 0.20 : 0.08)))
                    .contentShape(Capsule())
                    .programButtonCursor(enabled: canSave)
                }
            }
            .padding(20)
            .frame(width: 520)
            .background(ProgramBoardGlassBackground(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 10)
            .onTapGesture { }
            .onAppear { titleFocused = true }
        }
    }

    private var selectedProject: ProgramBoardProjectTarget? {
        projects.first { $0.path == selectedProjectPath }
    }

    private var canSave: Bool {
        makeRequest(selectedProjectPath, title, description) != nil
    }
}

private struct ProgramColumnEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.mutedText)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .padding(.horizontal, 10)
            .background(ProgramCardBackground(cornerRadius: 14))
    }
}

private struct ProgramStatePanel: View {
    let title: String
    let detail: String?
    let reloadState: ProgramBoardReloadState
    let theme: ParticleFieldRenderer.Theme?
    let onRefresh: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgramBoardTitleBar(
                reloadState: reloadState,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 560)
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(width: 640, height: 360, alignment: .topLeading)
        .background(ProgramBoardGlassBackground(cornerRadius: 16))
        .shadow(color: ProgramBoardColumnChrome.shadowColor(for: theme), radius: 20, x: 0, y: -6)
        .contentShape(Rectangle())
        .onTapGesture { }
    }
}

private struct ProgramErrorStrip: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ProgramBoardStyle.red)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 12))
    }
}

private struct ProgramStartSessionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("Start Session")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(ProgramBoardStyle.primaryText.opacity(0.96))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .programButtonCursor()
        .help("Start a Relay Runner voice session")
    }
}

private struct ProgramEndSessionButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("End Session")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(ProgramBoardStyle.primaryText.opacity(0.96))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .programButtonCursor()
        .help("End the active Relay Runner voice session")
    }
}

private struct ProgramIconButton: View {
    let systemName: String
    let help: String
    let iconColor: Color
    let action: () -> Void

    init(
        systemName: String,
        help: String,
        iconColor: Color = ProgramBoardStyle.primaryText,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.iconColor = iconColor
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .programButtonCursor()
        .help(help)
    }
}

private struct ProgramReloadButton: View {
    let state: ProgramBoardReloadState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if state.isLoading {
                    ProgressView()
                        .scaleEffect(0.58)
                        .controlSize(.small)
                } else {
                    Image(systemName: state.iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state.iconColor)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.white.opacity(0.10)))
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(state.isLoading)
        .programButtonCursor(enabled: !state.isLoading)
        .help(state.helpText)
    }
}

private struct ProgramCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.black.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }
}

private struct ProgramBoardGlassBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        BoardGlassBackground(
            cornerRadius: cornerRadius,
            blendingMode: ProgramBoardBackdropStyle.glassBlendingMode
        )
    }
}

private struct ProgramInlineBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ProgramBoardStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5))
            .fixedSize()
    }
}

private struct ProgramBoardColumnChrome: ViewModifier {
    let theme: ParticleFieldRenderer.Theme?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
            .background(ProgramBoardGlassBackground(cornerRadius: 16))
            .shadow(color: Self.shadowColor(for: theme), radius: 20, x: 0, y: -6)
            .animation(.easeInOut(duration: 0.4), value: theme)
            .contentShape(Rectangle())
            .onTapGesture { }
    }

    static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
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

private extension View {
    func programColumnChrome(theme: ParticleFieldRenderer.Theme?) -> some View {
        modifier(ProgramBoardColumnChrome(theme: theme))
    }
}

private extension ProgramBoardLane {
    var redundantStateKeys: Set<String> {
        switch self {
        case .backlog:
            return ["backlog"]
        case .ready:
            return ["ready"]
        case .inProgress:
            return ["in_progress"]
        case .done:
            return ["done"]
        }
    }
}

private extension ProgramBoardReloadState {
    var statusText: String {
        switch self {
        case .idle:
            return "Workspace status"
        case .loading:
            return "Refreshing..."
        case .succeeded:
            return "Updated"
        case .failed:
            return "Refresh failed"
        }
    }

    var iconName: String {
        switch self {
        case .idle, .loading:
            return "arrow.clockwise"
        case .succeeded:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        }
    }

    var iconColor: Color {
        switch self {
        case .succeeded:
            return ProgramBoardStyle.green
        case .failed:
            return ProgramBoardStyle.red
        case .idle, .loading:
            return ProgramBoardStyle.primaryText
        }
    }

    var helpText: String {
        switch self {
        case .idle:
            return "Refresh program status"
        case .loading:
            return "Refreshing program status"
        case .succeeded:
            return "Program status updated"
        case .failed(let message):
            return "Refresh failed: \(message)"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum ProgramBoardStyle {
    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0)
    static let secondaryText = Color(.sRGB, red: 203 / 255, green: 213 / 255, blue: 225 / 255, opacity: 0.78)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.82)
    static let red = Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 1.0)
    static let green = Color(.sRGB, red: 52 / 255, green: 211 / 255, blue: 153 / 255, opacity: 1.0)
}
