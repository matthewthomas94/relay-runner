import AppKit
import SwiftUI

struct PermissionAppTarget: Identifiable, Equatable {
    let displayName: String
    let bundleURL: URL?

    var id: String {
        bundleURL?.path ?? displayName
    }
}

struct PermissionAppDragGuide: View {
    let title: String
    let detail: String
    let settingsPane: String
    let targets: [PermissionAppTarget]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app")
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.callout).bold()
            }
            HStack(alignment: .center, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(targets) { target in
                        draggableAppIcon(target)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.title3)

                permissionListMock
                    .frame(width: 210)
            }

            Text("Drag this icon into the window that just opened, then turn on its switch.")
                .font(.caption)
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

    @ViewBuilder
    private func draggableAppIcon(_ target: PermissionAppTarget) -> some View {
        let tile = VStack(spacing: 7) {
            DraggableAppIconView(
                bundleURL: target.bundleURL,
                size: targets.count == 1 ? 92 : 76
            )
            .frame(width: targets.count == 1 ? 92 : 76, height: targets.count == 1 ? 92 : 76)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                )
            Text(target.displayName)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: targets.count == 1 ? 150 : 128)
        .contextMenu {
            if target.bundleURL != nil {
                Button("Reveal in Finder") { reveal(target) }
            }
        }
        tile
    }

    private var permissionListMock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(settingsPane)
                .font(.caption).bold()
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Text("Allow the applications below to monitor input from your keyboard.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            Divider()

            mockPermissionRow(icon: "app", name: "App 1", enabled: true)
            mockPermissionRow(icon: "app", name: "App 2", enabled: true)
            mockPermissionRow(icon: "app", name: "App 3", enabled: true)

            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "minus")
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.5))
                Spacer()
                Text("Drop app here")
                    .font(.caption2).bold()
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

    private func mockPermissionRow(icon: String, name: String, enabled: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 18, height: 18)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Capsule()
                .fill(enabled ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 24, height: 13)
                .overlay(alignment: enabled ? .trailing : .leading) {
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

    private func reveal(_ target: PermissionAppTarget) {
        guard let url = target.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct DraggableAppIconView: NSViewRepresentable {
    let bundleURL: URL?
    let size: CGFloat

    func makeNSView(context: Context) -> AppFileDragView {
        AppFileDragView()
    }

    func updateNSView(_ view: AppFileDragView, context: Context) {
        view.bundleURL = bundleURL
        view.image = Self.icon(for: bundleURL)
        view.frame.size = NSSize(width: size, height: size)
    }

    private static func icon(for url: URL?) -> NSImage {
        if let url {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 92, height: 92))
    }
}

private final class AppFileDragView: NSImageView, NSDraggingSource {
    var bundleURL: URL?
    private var mouseDownEvent: NSEvent?

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

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let bundleURL,
              let image,
              let mouseDownEvent else {
            return
        }

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)

        beginDraggingSession(with: [item], event: mouseDownEvent, source: self)
        self.mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}
