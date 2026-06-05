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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "app.badge")
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.callout).bold()
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targets) { target in
                        appTile(target)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .font(.title3)

                settingsTile
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("If the app is missing from the list, drag the app tile into System Settings, or reveal it in Finder and drag the app from there.")
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
    private func appTile(_ target: PermissionAppTarget) -> some View {
        let tile = HStack(spacing: 8) {
            appIcon(for: target.bundleURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(target.displayName)
                    .font(.callout).bold()
                    .lineLimit(1)
                if let path = target.bundleURL?.path {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Reveal the app you use to run the agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if target.bundleURL != nil {
                Button("Reveal") { reveal(target) }
                    .font(.caption)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.25))
        )

        if let url = target.bundleURL {
            tile.onDrag {
                NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url.path as NSString)
            }
        } else {
            tile
        }
    }

    private var settingsTile: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "switch.2")
                .foregroundStyle(.secondary)
                .font(.title3)
                .frame(width: 24)
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

    private func appIcon(for url: URL?) -> some View {
        let image: NSImage
        if let url {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return Image(nsImage: image)
            .resizable()
            .frame(width: 28, height: 28)
    }

    private func reveal(_ target: PermissionAppTarget) {
        guard let url = target.bundleURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
