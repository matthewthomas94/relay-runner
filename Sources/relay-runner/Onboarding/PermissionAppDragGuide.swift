import AppKit
import SwiftUI

struct PermissionAppTarget: Identifiable, Equatable {
    let displayName: String
    let bundleURL: URL?

    var id: String {
        bundleURL?.path ?? displayName
    }
}

struct PermissionAppGoalRow: Identifiable, Equatable {
    let displayName: String
    let bundleURL: URL?
    let enabled: Bool

    var id: String {
        bundleURL?.path ?? displayName
    }

    var fallbackInitial: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() } ?? "?"
    }
}

struct PermissionAppDragGuide: View {
    let title: String
    let settingsPane: String
    let targets: [PermissionAppTarget]
    let highlightedTargetIDs: Set<String>

    init(title: String,
         settingsPane: String,
         targets: [PermissionAppTarget],
         highlightTargets: Bool = false) {
        self.title = title
        self.settingsPane = settingsPane
        self.targets = targets
        self.highlightedTargetIDs = Self.highlightedTargetIDs(for: targets, isActive: highlightTargets)
    }

    static func highlightedTargetIDs(for targets: [PermissionAppTarget], isActive: Bool) -> Set<String> {
        guard isActive else { return [] }
        return Set(targets.map(\.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.tint)
                Text(title)
                    .font(AppTypography.font(.cardHeading))
            }
            HStack(alignment: .center, spacing: 12) {
                LazyVGrid(columns: iconColumns, alignment: .leading, spacing: 10) {
                    ForEach(targets) { target in
                        draggableAppIcon(
                            target,
                            isHighlighted: highlightedTargetIDs.contains(target.id)
                        )
                    }
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(AppTypography.symbolFont(size: 17, weight: .semibold))

                permissionListMock
                    .frame(width: 168)
            }

            Text("Literally drag the relevant app icon into the window that just opened, then turn on its switch.")
                .font(AppTypography.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25))
        )
    }

    private var iconColumns: [GridItem] {
        let count = max(1, min(targets.count, 2))
        return Array(
            repeating: GridItem(.fixed(tileWidth), spacing: 8, alignment: .top),
            count: count
        )
    }

    private var iconSize: CGFloat {
        targets.count == 1 ? 68 : 48
    }

    private var tileWidth: CGFloat {
        targets.count == 1 ? 100 : 78
    }

    @ViewBuilder
    private func draggableAppIcon(_ target: PermissionAppTarget, isHighlighted: Bool) -> some View {
        let tile = VStack(spacing: 7) {
            DraggableAppIconView(
                bundleURL: target.bundleURL,
                size: iconSize
            )
            .frame(width: iconSize, height: iconSize)
            .padding(7)
            .background {
                iconTileBackground(isHighlighted: isHighlighted)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        Color.accentColor.opacity(isHighlighted ? 0.85 : 0.55),
                        lineWidth: isHighlighted ? 1.5 : 1
                    )
            )
            .shadow(
                color: isHighlighted ? Self.particleGlowColor.opacity(0.45) : .clear,
                radius: isHighlighted ? 10 : 0
            )
            Text(target.displayName)
                .font(AppTypography.font(.caption))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: tileWidth)
        .contextMenu {
            if target.bundleURL != nil {
                Button("Reveal in Finder") { reveal(target) }
            }
        }
        .accessibilityIdentifier(
            isHighlighted ? "permission-app-drag-target-highlight" : "permission-app-drag-target"
        )
        tile
    }

    @ViewBuilder
    private func iconTileBackground(isHighlighted: Bool) -> some View {
        if isHighlighted {
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                    .opacity(0.82)
                PermissionTargetParticleGlow()
                    .allowsHitTesting(false)
            }
        } else {
            Color(nsColor: .controlBackgroundColor)
        }
    }

    private static var particleGlowColor: Color {
        Color(
            hue: Double(ParticleFieldRenderer.Theme.tts.baseHue),
            saturation: Double(ParticleFieldRenderer.Theme.tts.baseSaturation),
            brightness: 0.95
        )
    }

    static func goalRows(for targets: [PermissionAppTarget]) -> [PermissionAppGoalRow] {
        targets.map {
            PermissionAppGoalRow(displayName: $0.displayName, bundleURL: $0.bundleURL, enabled: true)
        }
    }

    private var permissionListMock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(settingsPane)
                .font(AppTypography.font(.caption))
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)

            Divider()

            ForEach(Self.goalRows(for: targets)) { row in
                mockPermissionRow(row)
            }

            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(AppTypography.symbolFont(size: 9))
                    .foregroundStyle(.secondary)
                Image(systemName: "minus")
                    .font(AppTypography.symbolFont(size: 9))
                    .foregroundStyle(.secondary.opacity(0.5))
                Spacer()
                Text("Drop app here")
                    .font(AppTypography.font(.smallCaption))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.12))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.35))
        )
    }

    private func mockPermissionRow(_ row: PermissionAppGoalRow) -> some View {
        HStack(spacing: 7) {
            permissionRowIcon(row)
            Text(row.displayName)
                .font(AppTypography.font(.caption))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Capsule()
                .fill(row.enabled ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 24, height: 13)
                .overlay(alignment: row.enabled ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .padding(2)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private func permissionRowIcon(_ row: PermissionAppGoalRow) -> some View {
        if let bundleURL = row.bundleURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundleURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Text(row.fallbackInitial)
                .font(AppTypography.font(.smallCaption))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func reveal(_ target: PermissionAppTarget) {
        guard let url = target.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct PermissionTargetParticleGlow: NSViewRepresentable {
    func makeNSView(context: Context) -> PermissionTargetParticleGlowView {
        let view = PermissionTargetParticleGlowView()
        view.setActive(true)
        return view
    }

    func updateNSView(_ view: PermissionTargetParticleGlowView, context: Context) {
        view.setActive(true)
    }
}

private final class PermissionTargetParticleGlowView: NSView {
    private let particleField = PerimeterParticleField(
        theme: .tts,
        thicknessFraction: 0.48,
        falloffExponent: 0.85
    )
    private var attached = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
        updateBackingScale()
        particleField.setActive(window != nil, pulsing: true)
    }

    override func layout() {
        super.layout()
        attachIfNeeded()
        updateBackingScale()
        particleField.layoutInBounds(bounds)
    }

    func setActive(_ active: Bool) {
        attachIfNeeded()
        particleField.setActive(active, pulsing: true)
    }

    private func attachIfNeeded() {
        guard !attached else { return }
        particleField.attach(to: self)
        attached = true
    }

    private func updateBackingScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        particleField.setBackingScale(scale)
    }
}

struct DraggableAppIconView: NSViewRepresentable {
    let bundleURL: URL?
    let size: CGFloat
    var isEnabled: Bool = true
    var onUserInteraction: () -> Void = {}
    var onDragStateChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> AppFileDragView {
        AppFileDragView()
    }

    func updateNSView(_ view: AppFileDragView, context: Context) {
        view.bundleURL = bundleURL
        view.image = Self.icon(for: bundleURL)
        view.frame.size = NSSize(width: size, height: size)
        view.draggingEnabled = isEnabled
        view.onUserInteraction = onUserInteraction
        view.onDragStateChanged = onDragStateChanged
    }

    private static func icon(for url: URL?) -> NSImage {
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 92, height: 92))
    }
}

struct AppFileDragPayload {
    static let finderFileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let dragImageSize = CGSize(width: 72, height: 72)

    let item: NSDraggingItem

    static func make(url: URL, image: NSImage, cursorPoint: CGPoint) -> AppFileDragPayload {
        let item = NSDraggingItem(pasteboardWriter: AppFileDragPasteboardWriter(url: url))
        let dragImage = image.copy() as? NSImage ?? image
        dragImage.size = dragImageSize
        item.setDraggingFrame(draggingFrame(cursorPoint: cursorPoint), contents: dragImage)
        return AppFileDragPayload(item: item)
    }

    static func draggingFrame(cursorPoint: CGPoint,
                              imageSize: CGSize = dragImageSize) -> CGRect {
        CGRect(
            x: cursorPoint.x - imageSize.width / 2,
            y: cursorPoint.y - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }
}

final class AppFileDragPasteboardWriter: NSObject, NSPasteboardWriting {
    let url: URL
    private let nativeWriter: NSURL

    init(url: URL) {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        self.url = standardized
        self.nativeWriter = standardized as NSURL
        super.init()
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = nativeWriter.writableTypes(for: pasteboard)
        if !types.contains(AppFileDragPayload.finderFileListType) {
            types.append(AppFileDragPayload.finderFileListType)
        }
        return types
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == AppFileDragPayload.finderFileListType {
            return [url.path]
        }
        // Keep standard URL/file-url payloads native; System Settings is picky
        // about hand-built file-url strings.
        return nativeWriter.pasteboardPropertyList(forType: type)
    }

    func writingOptions(forType type: NSPasteboard.PasteboardType,
                        pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == AppFileDragPayload.finderFileListType {
            return []
        }
        return nativeWriter.writingOptions(forType: type, pasteboard: pasteboard)
    }
}

final class AppFileDragView: NSImageView, NSDraggingSource {
    static let dragThreshold: CGFloat = 4

    var bundleURL: URL?
    var draggingEnabled = true
    var onUserInteraction: () -> Void = {}
    var onDragStateChanged: (Bool) -> Void = { _ in }
    private var mouseDownPoint: NSPoint?
    private var dragSessionActive = false
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        isEditable = false
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        imageScaling = .scaleProportionallyUpOrDown
        isEditable = false
        unregisterDraggedTypes()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onUserInteraction()
    }

    override func mouseMoved(with event: NSEvent) {
        onUserInteraction()
    }

    override func mouseDown(with event: NSEvent) {
        onUserInteraction()
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragSessionActive = false
    }

    override func mouseDragged(with event: NSEvent) {
        onUserInteraction()
        guard let bundleURL,
              let image,
              let mouseDownPoint,
              draggingEnabled,
              !dragSessionActive else {
            return
        }

        let currentPoint = convert(event.locationInWindow, from: nil)
        guard currentPoint.distance(to: mouseDownPoint) >= Self.dragThreshold else {
            return
        }

        let payload = AppFileDragPayload.make(url: bundleURL, image: image, cursorPoint: currentPoint)
        dragSessionActive = true
        onDragStateChanged(true)

        beginDraggingSession(with: [payload.item], event: event, source: self)
        self.mouseDownPoint = nil
    }

    override func mouseUp(with event: NSEvent) {
        onUserInteraction()
        mouseDownPoint = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragSessionActive = false
        onDragStateChanged(false)
    }
}

private extension NSPoint {
    func distance(to other: NSPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
