import AppKit
import CoreText
import SwiftUI

enum AppTypography {
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

        var nsFontWeight: NSFont.Weight {
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
        case appTitle
        case onboardingHero
        case screenTitle
        case workspaceHeading
        case programProjectsHeading
        case sectionHeading
        case cardHeading
        case controlHeading
        case projectTitle
        case ticketTitle
        case pillTitle
        case pillBody
        case notchStatus
        case body
        case label
        case field
        case metadata
        case supporting
        case settingsDescription
        case action
        case programAction
        case programEmptyState
        case permissionButton
        case button
        case status
        case count
        case caption
        case smallCaption
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

    static func font(
        _ role: Role,
        size: CGFloat,
        availablePostScriptNames: Set<String> = installedPostScriptNames
    ) -> Font {
        let resolved = resolved(role, availablePostScriptNames: availablePostScriptNames)
        if let postScriptName = resolved.postScriptName {
            return .custom(postScriptName, size: size)
        }
        return .system(size: size, weight: resolved.fallbackWeight.fontWeight)
    }

    static func appKitFont(
        _ role: Role,
        availablePostScriptNames: Set<String> = installedPostScriptNames
    ) -> NSFont {
        let resolved = resolved(role, availablePostScriptNames: availablePostScriptNames)
        if let postScriptName = resolved.postScriptName,
           let font = NSFont(name: postScriptName, size: resolved.size) {
            return font
        }
        return NSFont.systemFont(ofSize: resolved.size, weight: resolved.fallbackWeight.nsFontWeight)
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
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .appTitle:
            return Definition(face: .ppMoriSemibold, size: 22, fallbackWeight: .semibold)
        case .onboardingHero:
            return Definition(face: .ppTelegrafRegular, size: 48, fallbackWeight: .regular)
        case .screenTitle:
            return Definition(face: .ppMoriSemibold, size: 17, fallbackWeight: .semibold)
        case .workspaceHeading:
            return Definition(face: .ppMoriSemibold, size: 14, fallbackWeight: .semibold)
        case .programProjectsHeading:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .sectionHeading:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .cardHeading:
            return Definition(face: .ppMoriSemibold, size: 12, fallbackWeight: .semibold)
        case .controlHeading:
            return Definition(face: .ppMoriSemibold, size: 11, fallbackWeight: .semibold)
        case .projectTitle:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .ticketTitle:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .pillTitle:
            return Definition(face: .ppMoriSemibold, size: 13, fallbackWeight: .semibold)
        case .pillBody:
            return Definition(face: .ppTelegrafRegular, size: 14, fallbackWeight: .regular)
        case .notchStatus:
            return Definition(face: .ppMoriSemibold, size: 12, fallbackWeight: .semibold)
        case .body:
            return Definition(face: .ppTelegrafRegular, size: 12, fallbackWeight: .regular)
        case .label:
            return Definition(face: .ppTelegrafRegular, size: 11, fallbackWeight: .regular)
        case .field:
            return Definition(face: .ppTelegrafRegular, size: 13, fallbackWeight: .regular)
        case .metadata:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .supporting:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .settingsDescription:
            return Definition(face: .ppTelegrafRegular, size: 11, fallbackWeight: .regular)
        case .action:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .programAction:
            return Definition(face: .ppTelegrafRegular, size: 11, fallbackWeight: .regular)
        case .programEmptyState:
            return Definition(face: .ppTelegrafRegular, size: 13, fallbackWeight: .regular)
        case .permissionButton:
            return Definition(face: .ppMoriSemibold, size: 16, fallbackWeight: .semibold)
        case .button:
            return Definition(face: .ppTelegrafRegular, size: 11, fallbackWeight: .regular)
        case .status:
            return Definition(face: .ppMoriSemibold, size: 12, fallbackWeight: .semibold)
        case .count:
            return Definition(face: .ppTelegrafRegular, size: 10, fallbackWeight: .regular)
        case .caption:
            return Definition(face: .ppTelegrafRegular, size: 9, fallbackWeight: .regular)
        case .smallCaption:
            return Definition(face: .ppTelegrafRegular, size: 8, fallbackWeight: .regular)
        }
    }

    static func symbolFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func monospacedFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func terminalGridFont(size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static let installedPostScriptNames: Set<String> = {
        guard let names = CTFontManagerCopyAvailablePostScriptNames() as? [String] else {
            return []
        }
        return Set(names)
    }()
}
