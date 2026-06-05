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
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

                settingsTile
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Drag the large app icon into the Settings list. If macOS will not accept the drag from here, reveal it in Finder and drag the app from there.")
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
            appIcon(for: target.bundleURL, size: targets.count == 1 ? 92 : 76)
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
            if let path = target.bundleURL?.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 128)
            }
            if target.bundleURL != nil {
                Button("Reveal in Finder") { reveal(target) }
                    .font(.caption)
            }
        }
        .frame(width: targets.count == 1 ? 150 : 128)

        if let url = target.bundleURL {
            tile.onDrag {
                NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url.path as NSString)
            }
        } else {
            tile
        }
    }

    private var settingsTile: some View {
        VStack(alignment: .center, spacing: 8) {
            Image(systemName: "switch.2")
                .foregroundStyle(.secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(settingsPane)
                    .font(.callout).bold()
                Text("Privacy & Security list")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func appIcon(for url: URL?, size: CGFloat) -> some View {
        let image: NSImage
        if let url {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return Image(nsImage: image)
            .resizable()
            .frame(width: size, height: size)
    }

    private func reveal(_ target: PermissionAppTarget) {
        guard let url = target.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
