import Foundation
import Observation

/// The icon the user picked for each project in the Workspace's Projects
/// panel, kept by project path. A project without a pick shows `defaultIcon`.
@Observable
final class ProjectIconStore {
    static let shared = ProjectIconStore()
    static let defaultIcon: LucideIcon = .layers

    @ObservationIgnored private let fileURL: URL
    /// Lucide icon names by normalized project path.
    private var iconNames: [String: String]

    init(fileURL: URL = ProjectIconStore.defaultFileURL) {
        self.fileURL = fileURL
        iconNames = Self.load(from: fileURL)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("relay-runner", isDirectory: true)
            .appendingPathComponent("project-icons.json")
    }

    func icon(for path: String) -> LucideIcon {
        iconNames[ProgramBoardProjectPath.normalized(path)].flatMap(LucideIcon.init(rawValue:)) ?? Self.defaultIcon
    }

    func setIcon(_ icon: LucideIcon, for path: String) {
        iconNames[ProgramBoardProjectPath.normalized(path)] = icon.rawValue
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: iconNames, options: [.sortedKeys])
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[relay-runner] Could not save project icons: \(error.localizedDescription)")
        }
    }

    private static func load(from fileURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }
}
