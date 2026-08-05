import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ProgramBoardBackdropStyle {
    static let backdropOpacity: Double = 1.0
    static let bottomPadding: CGFloat = 22
    static var bottomCornerRadius: CGFloat {
        BoardDarkSurfaceStyle.workspaceCornerRadius
    }

    static var backdropHeight: CGFloat {
        BoardSurfaceLayout.columnTopPadding + BoardSurfaceLayout.columnHeight + bottomPadding
    }
}

enum ProgramBoardLayout {
    static let panelHorizontalPadding: CGFloat = 8
    static let panelVerticalPadding: CGFloat = 16
    static let headerHorizontalInset: CGFloat = 16
    static let headerLeadingInset: CGFloat = panelHorizontalPadding + headerHorizontalInset
    static let projectsHeaderHeight: CGFloat = 32
    static let projectActionButtonHeight: CGFloat = SharedActionButtonMetrics.controlHeight
    static let compactControlHeight: CGFloat = 24
    static let newTicketButtonSize: CGFloat = compactControlHeight
    static let workHeaderHeight: CGFloat = 36
    static let overviewSectionSpacing: CGFloat = 12
    static let projectHeaderToListSpacing: CGFloat = 48
    static let workSectionSpacing: CGFloat = 16
    static let dropIndicatorHeight: CGFloat = 3
    static let dropIndicatorBottomPadding: CGFloat = 4
    static let workCardTopOffset: CGFloat = 100
    static var workScrollTopPadding: CGFloat {
        workCardTopOffset
            - panelVerticalPadding
            - workHeaderHeight
            - workSectionSpacing
            - dropIndicatorHeight
            - dropIndicatorBottomPadding
    }
    static var projectListTopOffset: CGFloat {
        panelVerticalPadding
            + projectsHeaderHeight
            + projectHeaderToListSpacing
    }
    static var projectScrollContentInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 28, trailing: 0)
    }
    static var workScrollContentInsets: EdgeInsets {
        EdgeInsets(top: workScrollTopPadding, leading: 0, bottom: 28, trailing: 0)
    }
    static var emptyLaneBodyHeight: CGFloat {
        BoardSurfaceLayout.columnHeight
            - workCardTopOffset
            - panelVerticalPadding
    }
    static let projectCardHeight: CGFloat = 136
    static let projectCardSpacing: CGFloat = 8
    static let statePanelHeight: CGFloat = BoardSurfaceLayout.columnHeight
    static let statePanelHorizontalPadding: CGFloat = BoardSurfaceLayout.horizontalPadding
    static let sessionToolbarTopPadding: CGFloat = BoardSurfaceLayout.navigationTopPadding
    static let sessionToolbarTrailingPadding: CGFloat = 40
}

private enum ProgramTicketPanelStyle {
    static let width: CGFloat = 560
    static let height: CGFloat = 633
    static let horizontalPadding: CGFloat = 24
    static let verticalPadding: CGFloat = 18
    static let modalBackdropOpacity: Double = 0.55
}

struct ProgramBoardOverlayView: View {
    @Bindable var model: ProgramBoardViewModel
    @Bindable var workspace: WorkspaceViewModel
    let settingsContent: AnyView?
    let terminalContent: (String?) -> AnyView?
    let onDismiss: () -> Void
    let onWorkspaceTabChange: (WorkspaceTab) -> Void
    let onRefresh: () -> Void
    var onAddExistingProject: () -> Void = {}
    var onCreateProject: () -> Void = {}
    let onStartSession: () -> Void
    let onEndSession: () -> Void
    let onCreateStart: (ProgramBoardLane) -> Void
    let onCreateCommit: (ProgramBoardCreateRequest) -> Void
    let onCreateCancel: () -> Void
    let onEditStart: (ProgramTicketDetail) -> Void
    let onEditCommit: (ProgramBoardEditRequest) -> Void
    let onEditCancel: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void
    let onSpikeFollowupStart: (ProgramTicketDetail) -> Void
    let onSpikeFollowupReview: (SpikeFollowupBatch, SpikeFollowupProposal, String, [String: Any]?) -> Void
    let onSpikeFollowupClose: () -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ProgramBoardBackdropShape(cornerRadius: ProgramBoardBackdropStyle.bottomCornerRadius)
                .fill(Color.black.opacity(ProgramBoardBackdropStyle.backdropOpacity))
                .frame(maxWidth: .infinity)
                .frame(height: ProgramBoardBackdropStyle.backdropHeight)
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

            WorkspaceMenuBarStrip(
                workspace: workspace,
                hasActiveSession: model.hasActiveSession
            )
            .padding(.top, BoardSurfaceLayout.navigationTopPadding)
            .padding(.leading, 20)
            .zIndex(2)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ProgramSessionToolbarControl(
                    hasActiveSession: model.hasActiveSession,
                    canStartSession: ProgramSessionControlPolicy.canStart(
                        hasActiveSession: model.hasActiveSession,
                        selectedProjectPath: model.selectedSessionProjectPath,
                        requiresConfirmedProject: ProjectRegistryV2Rollout.isEnabled()
                    ),
                    onStartSession: onStartSession,
                    onEndSession: onEndSession
                )
            }
            .padding(.top, ProgramBoardLayout.sessionToolbarTopPadding)
            .padding(.trailing, ProgramBoardLayout.sessionToolbarTrailingPadding)
            .zIndex(2)

            if workspace.selectedTab == .terminal,
               let terminalContent = terminalContent(model.selectedSessionProjectPath) {
                VStack(spacing: 0) {
                    terminalContent
                        .padding(.top, BoardSurfaceLayout.columnTopPadding)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BoardSurfaceLayout.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            } else if workspace.selectedTab == .systemSettings, let settingsContent {
                VStack(spacing: 0) {
                    settingsContent
                        .padding(.top, BoardSurfaceLayout.columnTopPadding)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BoardSurfaceLayout.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            } else if workspace.showsWorkTab {
                VStack(spacing: 0) {
                    ProgramBoardContent(
                        model: model,
                        onRefresh: onRefresh,
                        onDismiss: onDismiss,
                        onAddExistingProject: onAddExistingProject,
                        onCreateProject: onCreateProject,
                        onCreateStart: onCreateStart,
                        onDrop: onDrop
                    )
                    .padding(.top, BoardSurfaceLayout.columnTopPadding)

                    Spacer(minLength: 0)
                }
            }

            ProgramDragPreviewLayer(model: model)

            if let detail = model.selectedTicketDetail,
               model.creating == nil,
               model.editing == nil,
               model.spikeFollowupBatch == nil {
                ProgramBoardModalLayer(onDismiss: model.clearSelectedTicket) {
                    ProgramTicketDetailPanel(
                        detail: detail,
                        theme: model.theme,
                        onClose: model.clearSelectedTicket,
                        onEdit: { onEditStart(detail) },
                        onDelete: onDelete,
                        onSpikeFollowup: { onSpikeFollowupStart(detail) }
                    )
                }
                .transition(.opacity)
            }

            if let draft = model.creating {
                ProgramBoardModalLayer(onDismiss: onCreateCancel) {
                    ProgramTicketCreateModal(
                        draft: draft,
                        projects: model.projectTargets,
                        makeRequest: { selectedProjectPath, title, description, executionMode, imageURLs in
                            model.createRequest(
                                selectedProjectPath: selectedProjectPath,
                                title: title,
                                description: description,
                                executionMode: executionMode,
                                imageURLs: imageURLs
                            )
                        },
                        onCommit: onCreateCommit,
                        onCancel: onCreateCancel
                    )
                }
                .id("\(draft.lane.id)-\(draft.selectedProjectPath ?? "all")")
                .transition(.opacity)
            }

            if let draft = model.editing {
                ProgramBoardModalLayer(onDismiss: onEditCancel) {
                    ProgramTicketEditModal(
                        draft: draft,
                        makeRequest: { title, status, priority, executionMode, description, acceptanceCriteria, imageURLs in
                            model.editRequest(
                                title: title,
                                status: status,
                                priority: priority,
                                executionMode: executionMode,
                                description: description,
                                acceptanceCriteria: acceptanceCriteria,
                                imageURLs: imageURLs
                            )
                        },
                        onCommit: onEditCommit,
                        onCancel: onEditCancel,
                        onDelete: onDelete
                    )
                }
                .id(draft.id)
                .transition(.opacity)
            }

            if let batch = model.spikeFollowupBatch {
                ProgramBoardModalLayer(onDismiss: onSpikeFollowupClose) {
                    ProgramSpikeFollowupReviewModal(
                        batch: batch,
                        onReview: onSpikeFollowupReview,
                        onClose: onSpikeFollowupClose
                    )
                }
                .id(batch.id)
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: "programBoard")
        .background(
            ProgramBoardWindowFrameReader { frame in
                model.updateBoardFrameInWindow(frame)
            }
        )
        .ignoresSafeArea(edges: .top)
        .onChange(of: workspace.selectedTab) { _, tab in
            onWorkspaceTabChange(tab)
        }
        .onPreferenceChange(ProgramColumnFramesKey.self) { model.columnFrames = $0 }
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

private struct ProgramBoardModalLayer<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    init(onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        ZStack {
            ProgramBoardBackdropShape(cornerRadius: ProgramBoardBackdropStyle.bottomCornerRadius)
                .fill(Color.black.opacity(ProgramTicketPanelStyle.modalBackdropOpacity))
                .contentShape(
                    ProgramBoardBackdropShape(cornerRadius: ProgramBoardBackdropStyle.bottomCornerRadius)
                )
                .onTapGesture(perform: onDismiss)

            content
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProgramBoardBackdropStyle.backdropHeight)
        .frame(maxHeight: .infinity, alignment: .top)
        .zIndex(3)
    }
}

private struct ProgramColumnFramesKey: PreferenceKey {
    typealias Value = [ProgramBoardLane: CGRect]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

private struct ProgramBoardWindowFrameReader: NSViewRepresentable {
    let onChange: (CGRect) -> Void

    func makeNSView(context: Context) -> ProgramBoardWindowFrameReaderView {
        ProgramBoardWindowFrameReaderView(onChange: onChange)
    }

    func updateNSView(_ nsView: ProgramBoardWindowFrameReaderView, context: Context) {
        nsView.onChange = onChange
        nsView.reportFrame()
    }
}

private final class ProgramBoardWindowFrameReaderView: NSView {
    var onChange: (CGRect) -> Void
    private var lastFrame: CGRect = .null

    init(onChange: @escaping (CGRect) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        onChange = { _ in }
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    func reportFrame() {
        guard window != nil else { return }
        let frame = convert(bounds, to: nil)
        guard frame.width > 0,
              frame.height > 0,
              frame != lastFrame else {
            return
        }
        lastFrame = frame
        DispatchQueue.main.async { [weak self] in
            self?.onChange(frame)
        }
    }
}

private struct ProgramDragPreviewLayer: View {
    @Bindable var model: ProgramBoardViewModel

    var body: some View {
        if let drag = model.dragPreview {
            ProgramWorkCard(
                item: drag.item,
                isSelected: false,
                showsProjectContext: true,
                isDraggingSource: false,
                isHovered: false,
                onSelect: {}
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

private struct ProgramButtonCursor: ViewModifier {
    let enabled: Bool
    @State private var isPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    guard enabled, !isPushed else { return }
                    (enabled ? NSCursor.pointingHand : NSCursor.arrow).push()
                    isPushed = true
                } else if isPushed {
                    NSCursor.pop()
                    isPushed = false
                }
            }
            .onChange(of: enabled) { _, isEnabled in
                guard !isEnabled, isPushed else { return }
                NSCursor.pop()
                isPushed = false
            }
            .onDisappear {
                guard isPushed else { return }
                NSCursor.pop()
                isPushed = false
            }
    }
}

private extension View {
    func programButtonCursor(enabled: Bool = true) -> some View {
        modifier(ProgramButtonCursor(enabled: enabled))
    }
}

private enum ProgramBoardControlShape {
    case capsule
    case circle
    case rounded(CGFloat)
}

private struct ProgramBoardInteractiveBackground: View {
    let shape: ProgramBoardControlShape
    let presentation: ProgramBoardInteractionPresentation
    let disabled: Bool

    var body: some View {
        switch shape {
        case .capsule:
            Capsule()
                .fill(backgroundColor)
                .overlay(Capsule().fill(Color.white.opacity(presentation.fillOverlayOpacity)))
                .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 1))
        case .circle:
            Circle()
                .fill(backgroundColor)
                .overlay(Circle().fill(Color.white.opacity(presentation.fillOverlayOpacity)))
                .overlay(Circle().strokeBorder(strokeColor, lineWidth: 1))
        case .rounded(let radius):
            RoundedRectangle(cornerRadius: radius)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.white.opacity(presentation.fillOverlayOpacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
        }
    }

    private var backgroundColor: Color {
        if disabled {
            return BoardDarkSurfaceStyle.contentFill.opacity(0.55)
        }
        return presentation.usesHoverFill
            ? BoardDarkSurfaceStyle.hoverFill
            : BoardDarkSurfaceStyle.contentFill
    }

    private var strokeColor: Color {
        if disabled {
            return BoardDarkSurfaceStyle.border.opacity(0.55)
        }
        guard presentation.strokeOpacity > 0 else {
            return BoardDarkSurfaceStyle.border
        }
        return Color.white.opacity(presentation.strokeOpacity)
    }
}

private struct ProgramBoardControlChrome: ViewModifier {
    let disabled: Bool
    let selected: Bool
    let shape: ProgramBoardControlShape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var presentation: ProgramBoardInteractionPresentation {
        ProgramBoardInteractionPresentation.resolve(
            surface: .control,
            isEnabled: !disabled,
            isSelected: selected,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
    }

    func body(content: Content) -> some View {
        content
            .background(
                ProgramBoardInteractiveBackground(
                    shape: shape,
                    presentation: presentation,
                    disabled: disabled
                )
            )
            .contentShape(Rectangle())
            .animation(
                presentation.animationDuration == 0
                    ? nil
                    : .timingCurve(0.165, 0.84, 0.44, 1, duration: presentation.animationDuration),
                value: presentation
            )
            .focusable(!disabled)
            .focusEffectDisabled(true)
            .focused($isFocused)
            .onHover { isHovered = !disabled && $0 }
    }
}

private extension View {
    func programControlChrome(
        disabled: Bool = false,
        selected: Bool = false,
        shape: ProgramBoardControlShape = .capsule
    ) -> some View {
        modifier(ProgramBoardControlChrome(disabled: disabled, selected: selected, shape: shape))
    }
}

enum ProgramBoardContentPresentation: Equatable {
    case board
    case noRegisteredProjects
    case loadFailure
    case empty

    static func resolve(
        hasSnapshot: Bool,
        hasRegisteredProjects: Bool,
        reloadState: ProgramBoardReloadState
    ) -> ProgramBoardContentPresentation {
        guard hasSnapshot else {
            if case .failed = reloadState { return .loadFailure }
            return .empty
        }
        return hasRegisteredProjects ? .board : .noRegisteredProjects
    }
}

private struct ProgramBoardContent: View {
    @Bindable var model: ProgramBoardViewModel
    let onRefresh: () -> Void
    let onDismiss: () -> Void
    let onAddExistingProject: () -> Void
    let onCreateProject: () -> Void
    let onCreateStart: (ProgramBoardLane) -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void

    var body: some View {
        switch ProgramBoardContentPresentation.resolve(
            hasSnapshot: model.snapshot != nil,
            hasRegisteredProjects: model.snapshot?.hasRegisteredProjects ?? false,
            reloadState: model.reloadState
        ) {
        case .board:
            if let snapshot = model.snapshot {
                HStack(alignment: .top, spacing: BoardSurfaceLayout.columnSpacing) {
                    ProgramOverviewColumn(
                        snapshot: snapshot,
                        selectedProjectPath: model.selectedProjectPath,
                        selectedScopeTitle: model.selectedScopeTitle,
                        errorMessage: model.errorMessage,
                        theme: model.theme,
                        usesProjectRegistryV2: ProjectRegistryV2Rollout.isEnabled(),
                        onSelectAll: model.selectAllProjects,
                        onAddExistingProject: onAddExistingProject,
                        onCreateProject: onCreateProject,
                        onSelectProject: model.selectProject
                    )
                    ForEach(ProgramBoardLane.allCases) { lane in
                        ProgramWorkColumnPanel(
                            model: model,
                            lane: lane,
                            showsProjectContext: model.isAllSelected,
                            theme: model.theme,
                            canCreate: !model.projectTargets.isEmpty,
                            onCreate: { onCreateStart(lane) },
                            onDrop: onDrop
                        )
                    }
                }
                .padding(.horizontal, BoardSurfaceLayout.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        case .noRegisteredProjects:
            if model.snapshot != nil {
                ProgramStatePanel(
                    title: "No registered projects",
                    detail: nil,
                    reloadState: model.reloadState,
                    theme: model.theme,
                    onRefresh: nil,
                    onDismiss: onDismiss,
                    primaryActionTitle: "Add Existing Project",
                    primaryAction: onAddExistingProject,
                    secondaryActionTitle: "Create Project",
                    secondaryAction: onCreateProject
                )
                .padding(.horizontal, ProgramBoardLayout.statePanelHorizontalPadding)
            }
        case .loadFailure:
            ProgramStatePanel(
                title: "Work temporarily unavailable",
                detail: model.errorMessage ?? "Relay Runner orchestrator is not reachable.",
                reloadState: model.reloadState,
                theme: model.theme,
                onRefresh: onRefresh,
                onDismiss: onDismiss
            )
            .padding(.horizontal, ProgramBoardLayout.statePanelHorizontalPadding)
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
    let theme: ParticleFieldRenderer.Theme?
    let usesProjectRegistryV2: Bool
    let onSelectAll: () -> Void
    let onAddExistingProject: () -> Void
    let onCreateProject: () -> Void
    let onSelectProject: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgramProjectsHeader(
                isAllSelected: selectedProjectPath == nil,
                selectedScopeTitle: selectedScopeTitle,
                usesProjectRegistryV2: usesProjectRegistryV2,
                onSelectAll: onSelectAll,
                onAddExistingProject: onAddExistingProject,
                onCreateProject: onCreateProject
            )

            if let errorMessage {
                ProgramErrorStrip(message: errorMessage)
                    .padding(.top, ProgramBoardLayout.overviewSectionSpacing)
            }

            BoardOverlayScrollView(contentInsets: ProgramBoardLayout.projectScrollContentInsets) {
                VStack(alignment: .leading, spacing: ProgramBoardLayout.projectCardSpacing) {
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
            .padding(.top, ProgramBoardLayout.projectHeaderToListSpacing)

            Spacer(minLength: 0)
        }
        .programColumnChrome(theme: theme)
    }
}

struct ProgramProjectsHeaderPresentation: Equatable {
    let isAllSelected: Bool
    let selectedScopeTitle: String
    let usesProjectRegistryV2: Bool

    var actionTitle: String { usesProjectRegistryV2 ? "Add project" : "Select all" }
    var actionProminence: SharedActionButtonProminence { .secondary }
}

struct ProgramEditButtonPresentation: Equatable {
    let isEnabled: Bool
    let help: String
    let accessibilityLabel: String

    static func resolve(
        isEnabled: Bool,
        help: String,
        accessibilityLabel: String = "Edit ticket"
    ) -> ProgramEditButtonPresentation {
        ProgramEditButtonPresentation(
            isEnabled: isEnabled,
            help: help,
            accessibilityLabel: accessibilityLabel
        )
    }
}

struct ProgramSpikeFollowupActionPresentation: Equatable {
    let isVisible: Bool

    static func resolve(
        executionMode: Ticket.ExecutionMode?,
        status: Ticket.Status?,
        runID: Int?,
        spikeReport: String?
    ) -> ProgramSpikeFollowupActionPresentation {
        ProgramSpikeFollowupActionPresentation(
            isVisible: executionMode == .spike
                && status == .done
                && runID != nil
                && spikeReport?.isEmpty == false
        )
    }
}

private struct ProgramProjectsHeader: View {
    let isAllSelected: Bool
    let selectedScopeTitle: String
    let usesProjectRegistryV2: Bool
    let onSelectAll: () -> Void
    let onAddExistingProject: () -> Void
    let onCreateProject: () -> Void

    private var presentation: ProgramProjectsHeaderPresentation {
        ProgramProjectsHeaderPresentation(
            isAllSelected: isAllSelected,
            selectedScopeTitle: selectedScopeTitle,
            usesProjectRegistryV2: usesProjectRegistryV2
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects")
                    .font(AppTypography.font(.programProjectsHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                Text(presentation.selectedScopeTitle)
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if presentation.usesProjectRegistryV2 {
                ProgramAddProjectMenu(
                    title: presentation.actionTitle,
                    onAddExistingProject: onAddExistingProject,
                    onCreateProject: onCreateProject
                )
            } else {
                ProgramWorkspaceActionButton(
                    title: presentation.actionTitle,
                    systemName: nil,
                    prominence: presentation.actionProminence,
                    accessibilityLabel: "Show tickets from all projects",
                    help: "Show tickets from all projects",
                    action: onSelectAll
                )
            }
        }
        .padding(.horizontal, ProgramBoardLayout.headerHorizontalInset)
        .frame(height: ProgramBoardLayout.projectsHeaderHeight, alignment: .top)
    }
}

private enum ProgramAddProjectMenuMetrics {
    static let disclosureWidth: CGFloat = 32
    static let dividerWidth: CGFloat = 1
}

private struct ProgramAddProjectMenu: View {
    let title: String
    let onAddExistingProject: () -> Void
    let onCreateProject: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var palette: SharedActionButtonPalette { .settingsSecondary }

    private var presentation: SettingsActionPresentation {
        SettingsActionPresentation.resolve(
            isEnabled: true,
            isHovered: isHovered,
            isFocused: false,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Menu {
            Button("Add existing project", systemImage: "folder.badge.plus") {
                onAddExistingProject()
            }
            Button("Create new project", systemImage: "plus") {
                onCreateProject()
            }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                Text(title)
                    .font(AppTypography.font(.programAction))
                    .lineLimit(1)
                    .padding(.horizontal, SharedActionButtonMetrics.horizontalPadding)
                    .frame(height: SharedActionButtonMetrics.controlHeight)
                Rectangle()
                    .fill(
                        palette.stroke.opacity(
                            presentation.sharedStrokeOpacity(for: .secondary)
                        )
                    )
                    .frame(
                        width: ProgramAddProjectMenuMetrics.dividerWidth,
                        height: SharedActionButtonMetrics.controlHeight
                    )
                Image(systemName: "chevron.down")
                    .font(AppTypography.symbolFont(size: 9, weight: .semibold))
                    .frame(
                        width: ProgramAddProjectMenuMetrics.disclosureWidth,
                        height: SharedActionButtonMetrics.controlHeight
                    )
                    .accessibilityHidden(true)
            }
            .foregroundStyle(palette.foreground.opacity(presentation.foregroundOpacity))
            .frame(height: SharedActionButtonMetrics.controlHeight)
            .background(
                SharedActionButtonSurface(
                    prominence: .secondary,
                    presentation: presentation,
                    palette: palette
                )
            )
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SharedActionButtonMetrics.cornerRadius,
                    style: .continuous
                )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: presentation.animationDuration), value: presentation)
        .programButtonCursor(enabled: true)
        .accessibilityLabel("Add project")
        .help("Add an existing project or create a new project")
    }
}

private struct ProgramProjectCard: View {
    let item: ProgramStatusItem
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var isEnabled: Bool {
        item.project?.path != nil
    }

    private var presentation: ProgramBoardInteractionPresentation {
        ProgramBoardInteractionPresentation.resolve(
            surface: .projectCard,
            isEnabled: isEnabled,
            isSelected: isSelected,
            isHovered: isHovered,
            isFocused: isFocused,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.project?.name ?? "Unknown project")
                        .font(AppTypography.font(.projectTitle))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isSelected {
                        Text("Selected")
                            .font(AppTypography.font(.caption))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                    }
                }

                Text(item.project?.path ?? "unknown")
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProjectBoardOverview(item: item)

                if let stale = item.staleRuns, stale > 0 {
                    Text("\(stale) stale")
                        .font(AppTypography.font(.supporting))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(1)
                }

                if !item.providerHealth.isEmpty {
                    Text(item.providerHealth.joined(separator: "  "))
                        .font(AppTypography.font(.supporting))
                        .foregroundStyle(ProgramBoardStyle.red)
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: ProgramBoardLayout.projectCardHeight, alignment: .leading)
            .background(
                ProgramBoardInteractiveBackground(
                    shape: .rounded(BoardDarkSurfaceStyle.nestedCardCornerRadius),
                    presentation: presentation,
                    disabled: !isEnabled
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .animation(
            presentation.animationDuration == 0
                ? nil
                : .timingCurve(0.165, 0.84, 0.44, 1, duration: presentation.animationDuration),
            value: presentation
        )
        .focusable(isEnabled)
        .focusEffectDisabled(true)
        .focused($isFocused)
        .onHover { isHovered = isEnabled && $0 }
        .programButtonCursor(enabled: isEnabled)
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
            ProjectCount(label: "Done", value: item.doneTickets)
            ProjectCount(label: "In progress", value: item.inProgressTickets ?? item.activeRuns)
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
                .font(AppTypography.font(.caption))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
            Text("\(value ?? 0)")
                .font(AppTypography.font(.count))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
    }
}

struct ProgramWorkColumnPanel: View {
    @Bindable var model: ProgramBoardViewModel
    let lane: ProgramBoardLane
    let showsProjectContext: Bool
    let theme: ParticleFieldRenderer.Theme?
    let canCreate: Bool
    let onCreate: () -> Void
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

    private var scrollResetID: String {
        let scopeID = model.selectedProjectPath ?? "all"
        return "\(lane.id)-\(scopeID)"
    }

    var body: some View {
        let laneItems = items
        VStack(alignment: .leading, spacing: ProgramBoardLayout.workSectionSpacing) {
            HStack(alignment: .center, spacing: 8) {
                Text(lane.title)
                    .font(AppTypography.font(.sectionHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Text("\(laneItems.count)")
                    .font(AppTypography.font(.count))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .monospacedDigit()
                if canCreate {
                    ProgramIconButton(
                        systemName: "plus",
                        help: "New \(lane.title.lowercased()) ticket",
                        size: ProgramBoardLayout.newTicketButtonSize,
                        action: onCreate
                    )
                }
            }
            .padding(.horizontal, ProgramBoardLayout.headerHorizontalInset)
            .frame(height: ProgramBoardLayout.workHeaderHeight)

            ProgramColumnTicketScrollView(resetID: scrollResetID) {
                VStack(alignment: .leading, spacing: 0) {
                    ProgramDropIndicator(target: activeTarget)
                    if laneItems.isEmpty {
                        ProgramColumnEmpty(text: lane.emptyText)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(laneItems) { item in
                                DraggableProgramWorkCard(
                                    model: model,
                                    item: item,
                                    lane: lane,
                                    isFirst: item.id == laneItems.first?.id,
                                    isLast: item.id == laneItems.last?.id,
                                    isSelected: model.selectedTicketDetail?.id == item.id,
                                    showsProjectContext: showsProjectContext,
                                    onSelect: { model.selectTicket(item) },
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

struct ProgramColumnTicketScrollView<Content: View>: View {
    let resetID: AnyHashable?
    @ViewBuilder let content: Content

    init(resetID: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.resetID = resetID
        self.content = content()
    }

    var body: some View {
        BoardOverlayScrollView(contentInsets: ProgramBoardLayout.workScrollContentInsets, resetID: resetID) {
            content
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
            .frame(height: ProgramBoardLayout.dropIndicatorHeight)
            .padding(.horizontal, 4)
            .padding(.bottom, ProgramBoardLayout.dropIndicatorBottomPadding)
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
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let showsProjectContext: Bool
    let onSelect: () -> Void
    let onDrop: (_ item: ProgramStatusItem, _ sourceLane: ProgramBoardLane, _ targetLane: ProgramBoardLane) -> Void
    @State private var isHovered = false

    private var isBeingDragged: Bool {
        model.dragItemID == item.id
    }

    private var canDrag: Bool {
        item.isProgramBoardDraggable
    }

    var body: some View {
        ProgramWorkCard(
            item: item,
            isSelected: isSelected,
            showsProjectContext: showsProjectContext,
            isDraggingSource: isBeingDragged,
            isHovered: isHovered,
            onSelect: onSelect
        )
            .opacity(isBeingDragged ? 0.25 : 1.0)
            .contentShape(Rectangle())
            .overlay(
                ProgramWorkCardDragEventLayer(
                    interactionID: "\(model.selectedProjectPath ?? "all")|\(lane.id)|\(item.id)",
                    canDrag: canDrag,
                    scrollBoundary: scrollBoundary,
                    toolTip: ProgramWorkCard.toolTip(for: item),
                    onHoverChange: { isHovered = $0 },
                    onSelect: onSelect,
                    windowLocationToBoardLocation: { location in
                        model.boardLocation(fromWindowLocation: location)
                    },
                    onChanged: { location, startLocation, cardCenterOffset in
                        updateDrag(
                            location: location,
                            startLocation: startLocation,
                            cardCenterOffset: cardCenterOffset
                        )
                    },
                    onEnded: endDrag,
                    onCancelled: cancelDrag
                )
            )
            .help(canDrag ? "Drag ticket to another lane" : "This ticket cannot be dragged while a worker owns its state")
    }

    private var scrollBoundary: BoardOverlayScrollBoundary? {
        guard isFirst || isLast else { return nil }
        return BoardOverlayScrollBoundary(
            topInset: isFirst
                ? ProgramBoardLayout.workScrollContentInsets.top
                    + ProgramBoardLayout.dropIndicatorHeight
                    + ProgramBoardLayout.dropIndicatorBottomPadding
                : nil,
            bottomInset: isLast ? ProgramBoardLayout.workScrollContentInsets.bottom : nil
        )
    }

    private func updateDrag(
        location: CGPoint,
        startLocation: CGPoint,
        cardCenterOffset: CGSize
    ) {
        guard canDrag else { return }
        let target = model.dropTarget(
            at: location,
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
                    location: location,
                    cardCenterOffset: cardCenterOffset,
                    target: target
                )
            } else {
                model.updateDrag(location: location, target: target)
            }
        }
    }

    private func endDrag() {
        guard model.dragItemID == item.id else { return }
        if canDrag, let target = model.dragTarget, target.isValid {
            onDrop(item, lane, target.lane)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.endDrag()
        }
    }

    private func cancelDrag() {
        guard model.dragItemID == item.id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.endDrag()
        }
    }

}

private struct ProgramWorkCardDragEventLayer: NSViewRepresentable {
    let interactionID: String
    let canDrag: Bool
    let scrollBoundary: BoardOverlayScrollBoundary?
    let toolTip: String
    let onHoverChange: (Bool) -> Void
    let onSelect: () -> Void
    let windowLocationToBoardLocation: (CGPoint) -> CGPoint?
    let onChanged: (
        _ location: CGPoint,
        _ startLocation: CGPoint,
        _ cardCenterOffset: CGSize
    ) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void

    func makeNSView(context: Context) -> ProgramWorkCardDragEventView {
        ProgramWorkCardDragEventView()
    }

    func updateNSView(_ nsView: ProgramWorkCardDragEventView, context: Context) {
        nsView.interactionID = interactionID
        nsView.boardOverlayScrollBoundary = scrollBoundary
        nsView.toolTip = toolTip
        nsView.onHoverChange = onHoverChange
        nsView.onSelect = onSelect
        nsView.windowLocationToBoardLocation = windowLocationToBoardLocation
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onCancelled = onCancelled
        nsView.canDrag = canDrag
        nsView.refreshMountedWorkCardRegistration()
        nsView.schedulePointerReconciliation()
    }
}

enum ProgramWorkCardCursorPresentation: Equatable {
    case arrow
    case openHand
    case closedHand

    static func resolve(canDrag: Bool, isDragging: Bool) -> Self {
        guard canDrag else { return .arrow }
        return isDragging ? .closedHand : .openHand
    }

    var cursor: NSCursor {
        switch self {
        case .arrow:
            return .arrow
        case .openHand:
            return .openHand
        case .closedHand:
            return .closedHand
        }
    }
}

final class ProgramWorkCardDragEventView: NSView, BoardOverlayScrollBoundaryProviding {
    static let dragThreshold: CGFloat = 5

    var interactionID = "" {
        didSet {
            guard interactionID != oldValue else { return }
            cancelPointerInteraction()
        }
    }
    var canDrag = false {
        didSet {
            guard canDrag != oldValue else { return }
            if !canDrag, isDragActive {
                cancelDrag()
            }
            refreshCursorPresentation()
        }
    }
    var boardOverlayScrollBoundary: BoardOverlayScrollBoundary?
    var onHoverChange: (Bool) -> Void = { _ in }
    var onSelect: () -> Void = {}
    var windowLocationToBoardLocation: (CGPoint) -> CGPoint? = { _ in nil }
    var onChanged: (
        _ location: CGPoint,
        _ startLocation: CGPoint,
        _ cardCenterOffset: CGSize
    ) -> Void = { _, _, _ in }
    var onEnded: () -> Void = {}
    var onCancelled: () -> Void = {}

    private(set) var isPointerInside = false
    private(set) var isDragActive = false
    var pointerLocationOverride: CGPoint?

    private var mouseDownLocation: CGPoint?
    private var mouseDownCardCenterOffset: CGSize?
    private weak var registeredScrollContainer: BoardOverlayScrollContainer?
    private var pointerReconciliationScheduled = false

    override var isFlipped: Bool { true }

    deinit {
        registeredScrollContainer?.unregisterMountedWorkCard(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        if let registeredScrollContainer {
            registeredScrollContainer.reconcileMountedPointer(
                atWindowLocation: event.locationInWindow
            )
            return
        }
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        if let registeredScrollContainer {
            registeredScrollContainer.reconcileMountedPointer(
                atWindowLocation: event.locationInWindow
            )
            return
        }
        setPointerInside(false)
    }

    override func mouseMoved(with event: NSEvent) {
        if let registeredScrollContainer {
            registeredScrollContainer.routeMountedPointer(
                to: self,
                atWindowLocation: event.locationInWindow
            )
            return
        }
        reconcilePointerContainment(atWindowLocation: event.locationInWindow)
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorPresentation.cursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorPresentation.cursor)
    }

    override func layout() {
        super.layout()
        refreshMountedWorkCardRegistration()
        schedulePointerReconciliation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            registeredScrollContainer?.unregisterMountedWorkCard(self)
            registeredScrollContainer = nil
            cancelPointerInteraction()
        } else {
            refreshMountedWorkCardRegistration()
            schedulePointerReconciliation()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            registeredScrollContainer?.unregisterMountedWorkCard(self)
            registeredScrollContainer = nil
            cancelPointerInteraction()
        } else {
            refreshMountedWorkCardRegistration()
            schedulePointerReconciliation()
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = boardLocation(for: event)
        mouseDownCardCenterOffset = mouseDownLocation.flatMap { startLocation in
            let centerInWindow = convert(
                CGPoint(x: bounds.midX, y: bounds.midY),
                to: nil
            )
            return windowLocationToBoardLocation(centerInWindow).map { center in
                CGSize(
                    width: center.x - startLocation.x,
                    height: center.y - startLocation.y
                )
            }
        }
        isDragActive = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard canDrag,
              let startLocation = mouseDownLocation,
              let cardCenterOffset = mouseDownCardCenterOffset,
              let location = boardLocation(for: event) else {
            return
        }
        guard isDragActive || hypot(location.x - startLocation.x, location.y - startLocation.y) >= Self.dragThreshold else {
            return
        }
        if !isDragActive {
            isDragActive = true
            refreshCursorPresentation()
        }
        NSCursor.closedHand.set()
        onChanged(location, startLocation, cardCenterOffset)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragActive {
            finishDrag()
        } else {
            onSelect()
            mouseDownLocation = nil
            mouseDownCardCenterOffset = nil
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancelPointerInteraction()
    }

    func reconcilePointerContainment(atWindowLocation location: CGPoint? = nil) {
        if let registeredScrollContainer {
            registeredScrollContainer.reconcileMountedPointer(
                atWindowLocation: location ?? pointerLocationOverride
            )
            return
        }
        guard let window, let contentView = window.contentView else {
            setPointerInside(false)
            return
        }
        let pointerLocation = location ?? pointerLocationOverride ?? window.mouseLocationOutsideOfEventStream
        let contentLocation = contentView.convert(pointerLocation, from: nil)
        var hitView = contentView.hitTest(contentLocation)
        while let candidate = hitView {
            if candidate === self {
                setPointerInside(true)
                return
            }
            hitView = candidate.superview
        }
        setPointerInside(false)
    }

    func schedulePointerReconciliation() {
        if let registeredScrollContainer {
            registeredScrollContainer.schedulePointerReconciliation()
            return
        }
        guard !pointerReconciliationScheduled else { return }
        pointerReconciliationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pointerReconciliationScheduled = false
            self.reconcilePointerContainment()
        }
    }

    var cursorPresentation: ProgramWorkCardCursorPresentation {
        ProgramWorkCardCursorPresentation.resolve(
            canDrag: canDrag,
            isDragging: isDragActive
        )
    }

    private func setPointerInside(_ isInside: Bool) {
        guard isPointerInside != isInside else { return }
        isPointerInside = isInside
        let hoverChange = onHoverChange
        DispatchQueue.main.async {
            hoverChange(isInside)
        }
        if isInside {
            refreshCursorPresentation()
        } else {
            window?.invalidateCursorRects(for: self)
        }
    }

    private func refreshCursorPresentation() {
        window?.invalidateCursorRects(for: self)
        guard isPointerInside || isDragActive else { return }
        cursorPresentation.cursor.set()
    }

    private func finishDrag() {
        guard isDragActive else { return }
        let onEnded = onEnded
        resetDragState()
        onEnded()
    }

    private func cancelDrag() {
        guard isDragActive else { return }
        let onCancelled = onCancelled
        resetDragState()
        onCancelled()
    }

    private func resetDragState() {
        mouseDownLocation = nil
        mouseDownCardCenterOffset = nil
        isDragActive = false
        if isPointerInside {
            refreshCursorPresentation()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func cancelPointerInteraction() {
        let ownedCursor = isPointerInside || isDragActive
        cancelDrag()
        mouseDownLocation = nil
        mouseDownCardCenterOffset = nil
        setPointerInside(false)
        window?.invalidateCursorRects(for: self)
        if ownedCursor {
            NSCursor.arrow.set()
        }
    }

    private func boardLocation(for event: NSEvent) -> CGPoint? {
        windowLocationToBoardLocation(event.locationInWindow)
    }

    func setMountedPointerInside(_ isInside: Bool) {
        setPointerInside(isInside)
    }

    func refreshMountedWorkCardRegistration() {
        let container = boardOverlayScrollContainerAncestor
        if registeredScrollContainer !== container {
            registeredScrollContainer?.unregisterMountedWorkCard(self)
            registeredScrollContainer = container
        }
        container?.registerMountedWorkCard(self)
    }
}

private struct ProgramWorkCard: View {
    let item: ProgramStatusItem
    let isSelected: Bool
    let showsProjectContext: Bool
    let isDraggingSource: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: ProgramBoardInteractionPresentation {
        ProgramBoardInteractionPresentation.resolve(
            surface: .ticketCard,
            isSelected: isSelected,
            isHovered: isHovered,
            isDraggingSource: isDraggingSource,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(metadataLine)
                    .font(AppTypography.font(.metadata))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }

            Text(title)
                .font(AppTypography.font(.ticketTitle))
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
                    .font(AppTypography.font(.supporting))
                    .foregroundStyle(item.blockedBy.isEmpty ? ProgramBoardStyle.secondaryText : ProgramBoardStyle.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            if let lastError = item.lastError, !lastError.isEmpty {
                Text(lastError)
                    .font(AppTypography.font(.supporting))
                    .foregroundStyle(ProgramBoardStyle.red)
                    .lineLimit(2)
            }

            if let activityLine {
                Text(activityLine)
                    .font(AppTypography.font(.supporting))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(activityLine)
                    .accessibilityLabel("Agent activity: \(activityLine)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ProgramBoardInteractiveBackground(
                shape: .rounded(BoardDarkSurfaceStyle.nestedCardCornerRadius),
                presentation: presentation,
                disabled: false
            )
        )
        .animation(
            presentation.animationDuration == 0
                ? nil
                : .timingCurve(0.165, 0.84, 0.44, 1, duration: presentation.animationDuration),
            value: presentation
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    static func toolTip(for item: ProgramStatusItem) -> String {
        let cleaned: (String?) -> String? = { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let projectName = cleaned(item.project?.name) ?? "Unknown project"
        let ticketID = cleaned(item.ticketID) ?? "No ticket"
        let title = cleaned(item.title) ?? "Untitled work"
        var parts = [projectName, ticketID, title]
        if let path = cleaned(item.project?.path) {
            parts.append(path)
        }
        return parts.joined(separator: " - ")
    }

    private var projectName: String {
        cleaned(item.project?.name) ?? "Unknown project"
    }

    private var ticketID: String {
        cleaned(item.ticketID) ?? "No ticket"
    }

    private var metadataLine: String {
        item.programCardMetadataParts.joined(separator: "  ")
    }

    private var title: String {
        cleaned(item.title) ?? "Untitled work"
    }

    private var stateBadges: [String] {
        var labels: [String] = []
        if item.isAwaitingMerge {
            labels.append("Awaiting review")
        }
        if item.isVerificationBlocked {
            labels.append("Verification blocked")
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

    private var activityLine: String? {
        item.programAgentActivityLine
    }

    private func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ProgramTicketDetailPanel: View {
    let detail: ProgramTicketDetail
    let theme: ParticleFieldRenderer.Theme?
    let onClose: () -> Void
    let onEdit: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void
    let onSpikeFollowup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail.identity?.ticketID ?? "No ticket")
                            .font(AppTypography.monospacedFont(size: 12, weight: .semibold))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .lineLimit(1)
                        if detail.item.isAwaitingMerge {
                            ProgramInlineBadge(label: "Awaiting review")
                        }
                        if detail.item.isVerificationBlocked {
                            ProgramInlineBadge(label: "Verification blocked")
                        }
                    }
                    Text(detail.title)
                        .font(AppTypography.font(.screenTitle))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                        .lineLimit(2)
                    Text(detail.projectName)
                        .font(AppTypography.font(.label))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .lineLimit(1)
                    if let projectPath = detail.identity?.projectPath {
                        Text(projectPath)
                            .font(AppTypography.monospacedFont(size: 10, weight: .regular))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Close ticket details", action: onClose)
            }

            HStack(alignment: .center, spacing: 8) {
                if detail.item.showsProgramBoardEditButton {
                    ProgramEditCapsuleButton(
                        presentation: ProgramEditButtonPresentation.resolve(
                            isEnabled: detail.ticket != nil,
                            help: detail.ticket == nil ? "Ticket file is unavailable" : "Edit child ticket"
                        )
                    ) {
                        onEdit()
                    }
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
                if canProposeSpikeFollowups {
                    ProgramDetailActionButton(
                        systemName: "arrow.triangle.branch",
                        title: "Follow-ups",
                        disabled: false,
                        help: "Propose implementation tickets from this spike"
                    ) {
                        onSpikeFollowup()
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
                    if let spikeReport = detail.spikeReport {
                        ProgramDetailSection(title: "Spike report", text: spikeReport)
                    }
                    if !detail.imageAttachments.isEmpty {
                        ProgramTicketImageSection(attachments: detail.imageAttachments)
                    }
                }
            }
        }
        .programTicketPanelChrome(theme: theme)
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

    private var canProposeSpikeFollowups: Bool {
        ProgramSpikeFollowupActionPresentation.resolve(
            executionMode: detail.ticket?.executionMode,
            status: detail.ticket?.status,
            runID: detail.ticket?.runId,
            spikeReport: detail.spikeReport
        ).isVisible
    }

    private var metadataRows: [ProgramDetailRow] {
        var rows: [ProgramDetailRow] = []
        append("Status", detail.item.status ?? detail.ticket?.status.rawValue, to: &rows)
        append("Priority", detail.item.priority ?? detail.ticket?.priority.rawValue, to: &rows)
        append("Execution mode", detail.item.executionMode ?? detail.ticket?.executionMode.rawValue, to: &rows)
        append("Ticket state", detail.item.ticketState, to: &rows)
        append("Run state", detail.item.runState, to: &rows)
        append("Run ID", detail.item.runID.map { "run \($0)" }, to: &rows, prettify: false)
        append("Attempt", detail.item.attempt, to: &rows, prettify: false)
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

private struct ProgramTicketPanelChrome: ViewModifier {
    let theme: ParticleFieldRenderer.Theme?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ProgramTicketPanelStyle.horizontalPadding)
            .padding(.vertical, ProgramTicketPanelStyle.verticalPadding)
            .frame(
                width: ProgramTicketPanelStyle.width,
                height: ProgramTicketPanelStyle.height,
                alignment: .topLeading
            )
            .background(
                ProgramBoardDarkSurfaceBackground(
                    cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius
                )
            )
            .shadow(
                color: ProgramBoardColumnChrome.shadowColor(for: theme),
                radius: BoardDarkSurfaceStyle.shadowRadius,
                x: 0,
                y: BoardDarkSurfaceStyle.shadowYOffset
            )
            .contentShape(Rectangle())
            .onTapGesture { }
    }
}

private extension View {
    func programTicketPanelChrome(
        theme: ParticleFieldRenderer.Theme? = nil
    ) -> some View {
        modifier(ProgramTicketPanelChrome(theme: theme))
    }
}

private struct ProgramSpikeFollowupReviewModal: View {
    let batch: SpikeFollowupBatch
    let onReview: (SpikeFollowupBatch, SpikeFollowupProposal, String, [String: Any]?) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spike follow-up tickets")
                        .font(AppTypography.font(.screenTitle))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                    Text("Review each proposal separately. Accepted tickets stay in Backlog.")
                        .font(AppTypography.font(.label))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                }
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Close follow-up proposals", action: onClose)
            }

            Text("\(batch.originTicketID) · spike run \(batch.originRunID)")
                .font(AppTypography.monospacedFont(size: 11, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.mutedText)

            BoardOverlayScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(batch.proposals) { proposal in
                        ProgramSpikeFollowupProposalCard(
                            batch: batch,
                            proposal: proposal,
                            onReview: onReview
                        )
                        }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 690, alignment: .topLeading)
        .background(
            ProgramBoardDarkSurfaceBackground(
                cornerRadius: BoardDarkSurfaceStyle.floatingPanelCornerRadius
            )
        )
        .contentShape(Rectangle())
        .onTapGesture { }
    }
}

private struct ProgramSpikeFollowupProposalCard: View {
    let batch: SpikeFollowupBatch
    let proposal: SpikeFollowupProposal
    let onReview: (SpikeFollowupBatch, SpikeFollowupProposal, String, [String: Any]?) -> Void

    @State private var title: String
    @State private var description: String
    @State private var acceptanceCriteria: String
    @State private var priority: String
    @State private var dependsOn: String
    @State private var workerModel: String
    @State private var workerEffort: String
    @State private var workerSizingRationale: String
    @State private var workerProviderNotes: String
    @State private var targetRepoPath: String

    init(
        batch: SpikeFollowupBatch,
        proposal: SpikeFollowupProposal,
        onReview: @escaping (SpikeFollowupBatch, SpikeFollowupProposal, String, [String: Any]?) -> Void
    ) {
        self.batch = batch
        self.proposal = proposal
        self.onReview = onReview
        _title = State(initialValue: proposal.draft.title)
        _description = State(initialValue: proposal.draft.description)
        _acceptanceCriteria = State(initialValue: proposal.draft.acceptanceCriteria.joined(separator: "\n"))
        _priority = State(initialValue: proposal.draft.priority)
        _dependsOn = State(initialValue: proposal.draft.dependsOn.joined(separator: ", "))
        _workerModel = State(initialValue: proposal.draft.workerModel)
        _workerEffort = State(initialValue: proposal.draft.workerEffort)
        _workerSizingRationale = State(initialValue: proposal.draft.workerSizingRationale)
        _workerProviderNotes = State(initialValue: proposal.draft.workerProviderNotes)
        _targetRepoPath = State(initialValue: proposal.draft.targetRepoPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(proposal.state.displayLabel)
                    .font(AppTypography.font(.caption))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                if let ticketID = proposal.ticketID {
                    Text(ticketID)
                        .font(AppTypography.monospacedFont(size: 11, weight: .semibold))
                        .foregroundStyle(ProgramBoardStyle.primaryText)
                }
                Spacer(minLength: 0)
            }

            TextField("Title", text: $title)
                .font(AppTypography.font(.body))
                .textFieldStyle(.roundedBorder)
                .disabled(!isDraft)
            TextField("Target project path", text: $targetRepoPath)
                .font(AppTypography.monospacedFont(size: 10, weight: .regular))
                .textFieldStyle(.roundedBorder)
                .disabled(!isDraft)

            ProgramEditTextArea(title: "Description", text: $description, minHeight: 64, maxHeight: 110)
                .disabled(!isDraft)
            ProgramEditTextArea(
                title: "Acceptance criteria (one per line)",
                text: $acceptanceCriteria,
                minHeight: 72,
                maxHeight: 130
            )
            .disabled(!isDraft)

            HStack(spacing: 8) {
                TextField("Priority", text: $priority)
                TextField("Dependencies", text: $dependsOn)
                TextField("Worker model", text: $workerModel)
                TextField("Effort", text: $workerEffort)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!isDraft)

            TextField("Sizing rationale", text: $workerSizingRationale)
                .textFieldStyle(.roundedBorder)
                .disabled(!isDraft)
            TextField("Provider notes", text: $workerProviderNotes)
                .textFieldStyle(.roundedBorder)
                .disabled(!isDraft)

            if let error = proposal.error, !error.isEmpty {
                ProgramDetailNotice(message: error)
            }

            if isDraft {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Save changes") { onReview(batch, proposal, "edit", updates) }
                    Button("Reject") { onReview(batch, proposal, "reject", nil) }
                    Button("Accept to Backlog") { onReview(batch, proposal, "accept", updates) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BoardDarkSurfaceStyle.contentFill)
        )
    }

    private var isDraft: Bool { proposal.state == "draft" }

    private var updates: [String: Any] {
        [
            "title": title,
            "description": description,
            "acceptance_criteria": acceptanceCriteria
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            "priority": priority,
            "depends_on": dependsOn
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            "worker_model": workerModel,
            "worker_effort": workerEffort,
            "worker_sizing_rationale": workerSizingRationale,
            "worker_provider_notes": workerProviderNotes,
            "target_repo_path": targetRepoPath,
        ]
    }
}

private struct ProgramTicketImageSection: View {
    let attachments: [ProgramTicketImageAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Images")
                .font(AppTypography.font(.body))
                .foregroundStyle(ProgramBoardStyle.secondaryText)

            ForEach(attachments) { attachment in
                switch attachment.state {
                case .preview(let url):
                    ProgramTicketImagePreview(url: url, attachment: attachment)
                case .failure(let reason):
                    ProgramTicketImageFailure(attachment: attachment, reason: reason)
                }
            }
        }
    }
}

private struct ProgramTicketImagePreview: View {
    let url: URL
    let attachment: ProgramTicketImageAttachment

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(attachment.accessibilityLabel)
        } else {
            ProgramTicketImageFailure(
                attachment: attachment,
                reason: "Image file could not be opened."
            )
        }
    }
}

private struct ProgramTicketImageFailure: View {
    let attachment: ProgramTicketImageAttachment
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                    .lineLimit(1)
                Text(reason)
                    .font(AppTypography.font(.label))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BoardDarkSurfaceStyle.contentFill)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(attachment.accessibilityLabel). \(reason)")
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
                            .font(AppTypography.font(.caption))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .lineLimit(1)
                        Text(row.value)
                            .font(AppTypography.font(.label))
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
                .font(AppTypography.font(.cardHeading))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .lineLimit(1)
            Text(text)
                .font(AppTypography.font(.label))
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
            .font(AppTypography.font(.status))
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
        ProgramWorkspaceActionButton(
            title: title,
            systemName: systemName,
            isEnabled: !disabled,
            accessibilityLabel: title,
            help: help,
            action: action,
            labelFont: .action,
            symbolSize: 11,
            destructive: destructive
        )
    }
}

private struct ProgramTicketEditModal: View {
    let draft: ProgramBoardEditDraft
    let makeRequest: (
        _ title: String,
        _ status: Ticket.Status,
        _ priority: Ticket.Priority,
        _ executionMode: Ticket.ExecutionMode,
        _ description: String,
        _ acceptanceCriteria: String,
        _ imageURLs: [URL]
    ) -> ProgramBoardEditRequest?
    let onCommit: (ProgramBoardEditRequest) -> Void
    let onCancel: () -> Void
    let onDelete: (ProgramBoardDeleteRequest) -> Void

    @State private var title: String
    @State private var status: Ticket.Status
    @State private var priority: Ticket.Priority
    @State private var executionMode: Ticket.ExecutionMode
    @State private var description: String
    @State private var acceptanceCriteria: String
    @State private var imageURLs: [URL] = []
    init(
        draft: ProgramBoardEditDraft,
        makeRequest: @escaping (
            _ title: String,
            _ status: Ticket.Status,
            _ priority: Ticket.Priority,
            _ executionMode: Ticket.ExecutionMode,
            _ description: String,
            _ acceptanceCriteria: String,
            _ imageURLs: [URL]
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
        self._executionMode = State(initialValue: draft.executionMode)
        self._description = State(initialValue: draft.description)
        self._acceptanceCriteria = State(initialValue: draft.acceptanceCriteria)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(draft.identity.ticketID)
                    .font(AppTypography.monospacedFont(size: 11, weight: .semibold))
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
                .font(AppTypography.monospacedFont(size: 10, weight: .regular))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)

            BoardOverlayScrollView(
                contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 10)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    ProgramTicketTitleField(text: $title)

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status")
                            .font(AppTypography.font(.controlHeading))
                            .foregroundStyle(ProgramBoardStyle.mutedText)
                            .textCase(.uppercase)
                        Picker("Status", selection: $status) {
                            ForEach(Ticket.Status.userSelectable, id: \.rawValue) { status in
                                Text(status.rawValue.displayLabel).tag(status)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Priority")
                            .font(AppTypography.font(.controlHeading))
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

                ProgramExecutionModePicker(selection: $executionMode)

                Divider()
                    .background(BoardDarkSurfaceStyle.border)

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

                ProgramTicketImageSelector(
                    existingPaths: draft.imageAttachmentPaths,
                    selectedURLs: $imageURLs
                )
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ProgramWorkspaceActionButton(
                    title: "Cancel",
                    systemName: "xmark",
                    accessibilityLabel: "Cancel ticket changes",
                    help: "Discard ticket changes",
                    action: onCancel,
                    labelFont: .action
                )
                .keyboardShortcut(.cancelAction)
                ProgramWorkspaceActionButton(
                    title: "Save",
                    systemName: "checkmark",
                    isEnabled: currentRequest != nil,
                    accessibilityLabel: "Save ticket changes",
                    help: currentRequest == nil ? "Complete the required fields" : "Save ticket changes",
                    action: {
                        if let request = currentRequest {
                            onCommit(request)
                        }
                    }
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .programTicketPanelChrome()
    }

    private var currentRequest: ProgramBoardEditRequest? {
        makeRequest(title, status, priority, executionMode, description, acceptanceCriteria, imageURLs)
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
                .font(AppTypography.font(.controlHeading))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .textCase(.uppercase)

            TextEditor(text: $text)
                .font(AppTypography.font(.field))
                .foregroundStyle(ProgramBoardStyle.secondaryText)
                .scrollContentBackground(.hidden)
                .frame(minHeight: minHeight, maxHeight: maxHeight)
                .padding(8)
                .background(ProgramTicketFieldBackground())
        }
    }
}

private struct ProgramTicketTitleField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Title")
                .font(AppTypography.font(.controlHeading))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .textCase(.uppercase)

            TextField("Enter ticket title", text: $text, axis: .vertical)
                .font(AppTypography.font(.screenTitle))
                .foregroundStyle(ProgramBoardStyle.primaryText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .lineLimit(1...3)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ProgramTicketFieldBackground())
        }
        .onAppear { isFocused = true }
    }
}

private struct ProgramTicketProjectPicker: View {
    let projects: [ProgramBoardProjectTarget]
    @Binding var selection: String?

    private var selectedProject: ProgramBoardProjectTarget? {
        projects.first { $0.path == selection }
    }

    var body: some View {
        Menu {
            Button {
                selection = nil
            } label: {
                if selection == nil {
                    Label("Select project", systemImage: "checkmark")
                } else {
                    Text("Select project")
                }
            }
            Divider()
            ForEach(projects) { project in
                Button {
                    selection = project.path
                } label: {
                    if selection == project.path {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedProject?.name ?? "Select project")
                    .font(AppTypography.font(.field))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Image(systemName: "chevron.down")
                    .font(AppTypography.symbolFont(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(ProgramBoardStyle.primaryText)
            .padding(.horizontal, 10)
            .frame(width: SettingsLayout.controlMaxWidth, height: 34)
            .background(ProgramTicketFieldBackground())
            .contentShape(
                RoundedRectangle(
                    cornerRadius: SettingsLayout.sidebarCornerRadius,
                    style: .continuous
                )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .programButtonCursor()
        .accessibilityLabel("Project")
        .help("Choose the project that will own this ticket")
    }
}

private struct ProgramTicketFieldBackground: View {
    var body: some View {
        RoundedRectangle(
            cornerRadius: SettingsLayout.sidebarCornerRadius,
            style: .continuous
        )
        .fill(BoardDarkSurfaceStyle.contentFill)
        .overlay(
            RoundedRectangle(
                cornerRadius: SettingsLayout.sidebarCornerRadius,
                style: .continuous
            )
            .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
        )
    }
}

private struct ProgramTicketCreateModal: View {
    let draft: ProgramBoardCreateDraft
    let projects: [ProgramBoardProjectTarget]
    let makeRequest: (
        _ selectedProjectPath: String?,
        _ title: String,
        _ description: String,
        _ executionMode: Ticket.ExecutionMode,
        _ imageURLs: [URL]
    ) -> ProgramBoardCreateRequest?
    let onCommit: (ProgramBoardCreateRequest) -> Void
    let onCancel: () -> Void

    @State private var selectedProjectPath: String?
    @State private var title: String
    @State private var description: String
    @State private var executionMode: Ticket.ExecutionMode = .implementation
    @State private var imageURLs: [URL] = []

    init(
        draft: ProgramBoardCreateDraft,
        projects: [ProgramBoardProjectTarget],
        makeRequest: @escaping (
            _ selectedProjectPath: String?,
            _ title: String,
            _ description: String,
            _ executionMode: Ticket.ExecutionMode,
            _ imageURLs: [URL]
        ) -> ProgramBoardCreateRequest?,
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                Text(draft.lane.title)
                    .font(AppTypography.monospacedFont(size: 11, weight: .semibold))
                    .foregroundStyle(ProgramBoardStyle.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Cancel new ticket", action: onCancel)
            }

            BoardOverlayScrollView(
                contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 10)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project")
                        .font(AppTypography.font(.controlHeading))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .textCase(.uppercase)
                    ProgramTicketProjectPicker(
                        projects: projects,
                        selection: $selectedProjectPath
                    )

                    Text(selectedProject?.path ?? "Select project")
                        .font(AppTypography.monospacedFont(size: 10, weight: .regular))
                        .foregroundStyle(ProgramBoardStyle.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                ProgramTicketTitleField(text: $title)

                ProgramExecutionModePicker(selection: $executionMode)

                Divider()
                    .background(BoardDarkSurfaceStyle.border)

                ProgramEditTextArea(
                    title: "Description",
                    text: $description,
                    minHeight: 190,
                    maxHeight: 280
                )

                ProgramTicketImageSelector(
                    existingPaths: [],
                    selectedURLs: $imageURLs
                )
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ProgramWorkspaceActionButton(
                    title: "Cancel",
                    systemName: "xmark",
                    accessibilityLabel: "Cancel new ticket",
                    help: "Discard the new ticket",
                    action: onCancel,
                    labelFont: .action
                )
                .keyboardShortcut(.cancelAction)
                ProgramWorkspaceActionButton(
                    title: "Save",
                    systemName: "checkmark",
                    isEnabled: canSave,
                    accessibilityLabel: "Save new ticket",
                    help: canSave ? "Save new ticket" : "Complete the required fields",
                    action: {
                        if let request = makeRequest(selectedProjectPath, title, description, executionMode, imageURLs) {
                            onCommit(request)
                        }
                    },
                    labelFont: .action
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .programTicketPanelChrome()
    }

    private var selectedProject: ProgramBoardProjectTarget? {
        projects.first { $0.path == selectedProjectPath }
    }

    private var canSave: Bool {
        makeRequest(selectedProjectPath, title, description, executionMode, imageURLs) != nil
    }
}

private struct ProgramExecutionModePicker: View {
    @Binding var selection: Ticket.ExecutionMode

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Execution mode")
                .font(AppTypography.font(.controlHeading))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .textCase(.uppercase)
            HStack(spacing: 0) {
                ForEach(Array(Ticket.ExecutionMode.allCases.enumerated()), id: \.element.rawValue) { index, mode in
                    if index > 0 {
                        Rectangle()
                            .fill(BoardDarkSurfaceStyle.border)
                            .frame(width: 1, height: 34)
                    }
                    ProgramExecutionModeButton(
                        mode: mode,
                        isSelected: selection == mode,
                        action: { selection = mode }
                    )
                }
            }
            .frame(maxWidth: 360)
            .background(ProgramTicketFieldBackground())
            .clipShape(
                RoundedRectangle(
                    cornerRadius: SettingsLayout.sidebarCornerRadius,
                    style: .continuous
                )
            )
            Text(selection.explanation)
                .font(AppTypography.font(.label))
                .foregroundStyle(ProgramBoardStyle.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProgramExecutionModeButton: View {
    let mode: Ticket.ExecutionMode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(mode.displayName)
                .font(AppTypography.font(.action))
                .foregroundStyle(
                    isSelected
                        ? ProgramBoardStyle.primaryText
                        : ProgramBoardStyle.secondaryText
                )
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(backgroundColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled(SettingsLayout.systemFocusEffectDisabled)
        .onHover { isHovered = $0 }
        .programButtonCursor()
        .accessibilityLabel(mode.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected {
            return SettingsSurfaceColor.rowFillSelected
        }
        return isHovered ? SettingsSurfaceColor.rowFillHovered : Color.clear
    }
}

private struct ProgramTicketImageSelector: View {
    let existingPaths: [String]
    @Binding var selectedURLs: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Images")
                    .font(AppTypography.font(.controlHeading))
                    .foregroundStyle(ProgramBoardStyle.mutedText)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                ProgramWorkspaceActionButton(
                    title: "Add images",
                    systemName: "photo.badge.plus",
                    accessibilityLabel: "Add ticket images",
                    help: "Attach design images to this ticket",
                    action: addImages,
                    labelFont: .action
                )
            }

            if existingPaths.isEmpty && selectedURLs.isEmpty {
                Text("Attach designs for the implementation worker.")
                    .font(AppTypography.font(.label))
                    .foregroundStyle(ProgramBoardStyle.disabledText)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(existingPaths, id: \.self) { path in
                            ProgramTicketImageChip(
                                name: URL(fileURLWithPath: path).lastPathComponent
                            )
                        }
                        ForEach(selectedURLs, id: \.self) { url in
                            ProgramTicketImageChip(
                                name: url.lastPathComponent,
                                onRemove: {
                                    selectedURLs.removeAll { $0 == url }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = "Choose design images to attach to this ticket."
        guard panel.runModal() == .OK else { return }

        for url in panel.urls where !selectedURLs.contains(url) {
            selectedURLs.append(url)
        }
    }
}

private struct ProgramTicketImageChip: View {
    let name: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(AppTypography.symbolFont(size: 11, weight: .medium))
            Text(name)
                .font(AppTypography.font(.label))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(AppTypography.symbolFont(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Remove image")
            }
        }
        .foregroundStyle(ProgramBoardStyle.secondaryText)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(BoardDarkSurfaceStyle.contentFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
        )
    }
}

private struct ProgramColumnEmpty: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppTypography.font(.programEmptyState))
            .foregroundStyle(ProgramBoardStyle.disabledText)
            .lineLimit(1)
            .frame(
                maxWidth: .infinity,
                minHeight: ProgramBoardLayout.emptyLaneBodyHeight,
                maxHeight: ProgramBoardLayout.emptyLaneBodyHeight,
                alignment: .center
            )
    }
}

private struct ProgramStatePanel: View {
    let title: String
    let detail: String?
    let reloadState: ProgramBoardReloadState
    let theme: ParticleFieldRenderer.Theme?
    let onRefresh: (() -> Void)?
    let onDismiss: () -> Void
    var primaryActionTitle: String? = nil
    var primaryAction: (() -> Void)? = nil
    var secondaryActionTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text("Status")
                    .font(AppTypography.font(.workspaceHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                Spacer(minLength: 0)
                ProgramIconButton(systemName: "xmark", help: "Close Workspace", action: onDismiss)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(title)
                    .font(AppTypography.font(.sectionHeading))
                    .foregroundStyle(ProgramBoardStyle.primaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.font(.supporting))
                        .foregroundStyle(ProgramBoardStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 560)
                }
                if let primaryActionTitle, let primaryAction {
                    HStack(spacing: 8) {
                        ProgramWorkspaceActionButton(
                            title: primaryActionTitle,
                            systemName: "folder.badge.plus",
                            accessibilityLabel: primaryActionTitle,
                            help: "Register an existing Git repository",
                            action: primaryAction
                        )
                        if let secondaryActionTitle, let secondaryAction {
                            ProgramWorkspaceActionButton(
                                title: secondaryActionTitle,
                                systemName: "plus",
                                accessibilityLabel: secondaryActionTitle,
                                help: "Create and register a new Git repository",
                                action: secondaryAction
                            )
                        }
                    }
                }
                if let onRefresh {
                    Button(action: onRefresh) {
                        Text("Refresh")
                            .font(AppTypography.font(.programAction))
                            .foregroundStyle(ProgramBoardStyle.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(height: ProgramBoardLayout.compactControlHeight)
                    }
                    .buttonStyle(.plain)
                    .disabled(reloadState.isLoading)
                    .programControlChrome(disabled: reloadState.isLoading)
                    .programButtonCursor(enabled: !reloadState.isLoading)
                    .help("Refresh registered projects")
                }
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(
            maxWidth: .infinity,
            minHeight: ProgramBoardLayout.statePanelHeight,
            maxHeight: ProgramBoardLayout.statePanelHeight,
            alignment: .topLeading
        )
        .background(ProgramBoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
        .shadow(
            color: ProgramBoardColumnChrome.shadowColor(for: theme),
            radius: BoardDarkSurfaceStyle.shadowRadius,
            x: 0,
            y: BoardDarkSurfaceStyle.shadowYOffset
        )
        .contentShape(Rectangle())
        .onTapGesture { }
    }
}

private struct ProgramErrorStrip: View {
    let message: String

    var body: some View {
        Text(message)
            .font(AppTypography.font(.supporting))
            .foregroundStyle(ProgramBoardStyle.red)
            .lineLimit(2)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProgramCardBackground(cornerRadius: 12))
    }
}

struct ProgramSessionToolbarPresentation: Equatable {
    let title: String
    let systemName: String
    let help: String

    static func resolve(hasActiveSession: Bool) -> ProgramSessionToolbarPresentation {
        hasActiveSession
            ? ProgramSessionToolbarPresentation(
                title: "End session",
                systemName: "stop.fill",
                help: "End the active Relay Runner voice session"
            )
            : ProgramSessionToolbarPresentation(
                title: "Start session",
                systemName: "play.fill",
                help: "Start a Relay Runner voice session"
            )
    }
}

enum ProgramSessionControlPolicy {
    static func canStart(
        hasActiveSession: Bool,
        selectedProjectPath: String?,
        requiresConfirmedProject: Bool
    ) -> Bool {
        hasActiveSession || !requiresConfirmedProject || selectedProjectPath != nil
    }
}

private struct ProgramSessionToolbarControl: View {
    let hasActiveSession: Bool
    let canStartSession: Bool
    let onStartSession: () -> Void
    let onEndSession: () -> Void

    private var presentation: ProgramSessionToolbarPresentation {
        ProgramSessionToolbarPresentation.resolve(hasActiveSession: hasActiveSession)
    }

    var body: some View {
        ProgramSessionButton(
            presentation: presentation,
            isEnabled: hasActiveSession || canStartSession
        ) {
            if hasActiveSession {
                onEndSession()
            } else {
                onStartSession()
            }
        }
    }
}

private struct ProgramSessionButton: View {
    let presentation: ProgramSessionToolbarPresentation
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        WorkspaceNavigationButton(
            title: presentation.title,
            systemName: presentation.systemName,
            accessibilityLabel: presentation.title,
            help: presentation.help,
            action: action
        )
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

private struct ProgramEditCapsuleButton: View {
    let presentation: ProgramEditButtonPresentation
    let action: () -> Void

    var body: some View {
        ProgramWorkspaceActionButton(
            title: "Edit",
            systemName: "pencil",
            isEnabled: presentation.isEnabled,
            accessibilityLabel: presentation.accessibilityLabel,
            help: presentation.help,
            action: action,
            labelFont: .action,
            symbolSize: 10
        )
    }
}

private struct ProgramWorkspaceActionButton: View {
    let title: String
    let systemName: String?
    var prominence: SharedActionButtonProminence = .secondary
    var isEnabled = true
    let accessibilityLabel: String
    let help: String
    let action: () -> Void
    var labelFont: AppTypography.Role = .programAction
    var symbolSize: CGFloat = 11
    var destructive = false

    var body: some View {
        SharedActionButtonChrome(
            prominence: prominence,
            isEnabled: isEnabled,
            accessibilityLabel: accessibilityLabel,
            helpText: help,
            palette: palette,
            action: action,
            label: {
            HStack(alignment: .center, spacing: 6) {
                if let systemName {
                    Image(systemName: systemName)
                        .font(AppTypography.symbolFont(size: symbolSize, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(AppTypography.font(labelFont))
                    .lineLimit(1)
            }
            }
        )
        .programButtonCursor(enabled: isEnabled)
    }

    private var palette: SharedActionButtonPalette {
        SharedActionButtonPalette(
            foreground: destructive ? ProgramBoardStyle.red : prominence == .primary ? ProgramBoardStyle.neutralText : ProgramBoardStyle.primaryText,
            fill: destructive ? ProgramBoardStyle.red : prominence == .primary ? ProgramBoardStyle.neutralText : Color.white,
            stroke: destructive ? ProgramBoardStyle.red : ProgramBoardStyle.neutralText
        )
    }
}

private struct ProgramIconButton: View {
    let systemName: String
    let help: String
    let iconColor: Color
    let size: CGFloat
    let action: () -> Void

    init(
        systemName: String,
        help: String,
        iconColor: Color = ProgramBoardStyle.primaryText,
        size: CGFloat = 22,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.help = help
        self.iconColor = iconColor
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppTypography.symbolFont(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .programControlChrome(shape: .circle)
        .programButtonCursor()
        .help(help)
    }
}

private struct ProgramCardBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        BoardDarkSurfaceBackground(
            cornerRadius: cornerRadius,
            fill: BoardDarkSurfaceStyle.contentFill
        )
    }
}

private struct ProgramBoardDarkSurfaceBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        BoardDarkSurfaceBackground(
            cornerRadius: cornerRadius,
            fill: BoardDarkSurfaceStyle.panelFill
        )
    }
}

private struct ProgramInlineBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(AppTypography.font(.caption))
            .foregroundStyle(ProgramBoardStyle.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(BoardDarkSurfaceStyle.contentFill)
                    .overlay(
                        Capsule()
                            .stroke(BoardDarkSurfaceStyle.border, lineWidth: 1)
                    )
            )
            .fixedSize()
    }
}

private struct ProgramBoardColumnChrome: ViewModifier {
    let theme: ParticleFieldRenderer.Theme?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, ProgramBoardLayout.panelHorizontalPadding)
            .padding(.vertical, ProgramBoardLayout.panelVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: BoardSurfaceLayout.columnHeight, maxHeight: BoardSurfaceLayout.columnHeight, alignment: .topLeading)
            .background(ProgramBoardDarkSurfaceBackground(cornerRadius: BoardDarkSurfaceStyle.columnCornerRadius))
            .shadow(
                color: Self.shadowColor(for: theme),
                radius: BoardDarkSurfaceStyle.shadowRadius,
                x: 0,
                y: BoardDarkSurfaceStyle.shadowYOffset
            )
            .animation(.easeInOut(duration: 0.4), value: theme)
            .contentShape(Rectangle())
            .onTapGesture { }
    }

    static func shadowColor(for theme: ParticleFieldRenderer.Theme?) -> Color {
        switch theme {
        case .stt, .tts, nil:
            return Color.black.opacity(BoardDarkSurfaceStyle.shadowOpacity)
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

enum ProgramBoardStyle {
    static let disabledTextNSColor = NSColor(srgbRed: 100 / 255, green: 116 / 255, blue: 139 / 255, alpha: 1)
    static let neutralTextNSColor = NSColor(srgbRed: 248 / 255, green: 250 / 255, blue: 252 / 255, alpha: 1)

    static let primaryText = Color(.sRGB, red: 226 / 255, green: 232 / 255, blue: 240 / 255, opacity: 1.0)
    static let secondaryText = Color(.sRGB, red: 203 / 255, green: 213 / 255, blue: 225 / 255, opacity: 0.78)
    static let mutedText = Color(.sRGB, red: 148 / 255, green: 163 / 255, blue: 184 / 255, opacity: 0.82)
    static let disabledText = Color(nsColor: disabledTextNSColor)
    static let neutralText = Color(nsColor: neutralTextNSColor)
    static let red = Color(.sRGB, red: 244 / 255, green: 60 / 255, blue: 9 / 255, opacity: 1.0)
    static let green = Color(.sRGB, red: 52 / 255, green: 211 / 255, blue: 153 / 255, opacity: 1.0)
}
