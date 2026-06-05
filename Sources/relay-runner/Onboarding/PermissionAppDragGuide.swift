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

                permissionListMock
                    .frame(width: 210)
            }

            Text("Drag the app icon into the list on the right, then turn on its switch.")
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
        }
        .frame(width: targets.count == 1 ? 150 : 128)
        .contextMenu {
            if target.bundleURL != nil {
                Button("Reveal in Finder") { reveal(target) }
            }
        }

        if let url = target.bundleURL {
            tile.onDrag {
                NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url.path as NSString)
            }
        } else {
            tile
        }
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

            mockPermissionRow(icon: "safari", name: "Arc", enabled: true)
            mockPermissionRow(icon: "circle.grid.cross", name: "Google Chrome", enabled: true)
            mockPermissionRow(icon: "keyboard", name: "keyviz", enabled: true)

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
