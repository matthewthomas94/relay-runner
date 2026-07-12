import CoreText
import SwiftUI

enum WorkspaceTypography {
    enum SystemWeight: Equatable {
        case regular
        case medium
        case semibold
        case bold

        var fontWeight: Font.Weight {
            switch self {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    enum Face: Equatable {
        case system
        case ppMoriRegular
        case ppMoriSemibold
        case ppTelegrafRegular

        var postScriptName: String? {
            switch self {
            case .system:
                return nil
            case .ppMoriRegular:
                return "PPMori-Regular"
            case .ppMoriSemibold:
                return "PPMori-SemiBold"
            case .ppTelegrafRegular:
                return "PPTelegraf-Regular"
            }
        }
    }

    enum Role: CaseIterable {
        case menuTab
        case workspaceHeading
        case sectionHeading
        case projectTitle
        case ticketTitle
        case metadata
        case supporting
        case action
        case count
        case caption
    }

    struct Definition: Equatable {
        let face: Face
        let size: CGFloat
        let fallbackWeight: SystemWeight
    }

    struct ResolvedFont: Equatable {
        let postScriptName: String?
        let size: CGFloat
        let fallbackWeight: SystemWeight
    }

    static func font(
        _ role: Role,
        availablePostScriptNames: Set<String> = installedPostScriptNames
    ) -> Font {
        let resolved = resolved(role, availablePostScriptNames: availablePostScriptNames)
        if let postScriptName = resolved.postScriptName {
            return .custom(postScriptName, size: resolved.size)
        }
        return .system(size: resolved.size, weight: resolved.fallbackWeight.fontWeight)
    }

    static func resolved(
        _ role: Role,
        availablePostScriptNames: Set<String>
    ) -> ResolvedFont {
        let definition = definition(for: role)
        let postScriptName = definition.face.postScriptName
        let resolvedPostScriptName: String?
        if let postScriptName, availablePostScriptNames.contains(postScriptName) {
            resolvedPostScriptName = postScriptName
        } else {
            resolvedPostScriptName = nil
        }
        return ResolvedFont(
            postScriptName: resolvedPostScriptName,
            size: definition.size,
            fallbackWeight: definition.fallbackWeight
        )
    }

    static func definition(for role: Role) -> Definition {
        switch role {
        case .menuTab:
            return Definition(face: .system, size: 13, fallbackWeight: .semibold)
        case .workspaceHeading:
            return Definition(face: .ppMoriSemibold, size: 14, fallbackWeight: .semibold)
        case .sectionHeading:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .projectTitle:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .ticketTitle:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .metadata:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .supporting:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .action:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .count:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .caption:
            return Definition(face: .ppTelegrafRegular, size: 9, fallbackWeight: .regular)
        }
    }

    private static let installedPostScriptNames: Set<String> = {
        guard let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] else {
            return []
        }
        return Set(names)
    }()
}
