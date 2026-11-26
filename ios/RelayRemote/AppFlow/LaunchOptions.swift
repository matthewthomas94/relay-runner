import Foundation

/// Debug-only launch arguments that open the app on a given screen, for
/// simulator screenshots:
/// - `--gallery` shows the design-system reference gallery, and
///   `--gallery=<page>` opens it on one of its pages,
/// - `--stage=<splash|permissions|pairing|tutorial|app>` starts at a stage,
/// - `--pairing-step=<scan|check>` opens the pairing flow on a step,
/// - `--tab=<agents|workspace|settings>` opens the app on a tab,
/// - `--reset-onboarding` forgets that onboarding finished, as a fresh install.
/// Release builds ignore them.
struct LaunchOptions: Equatable {
    var showsGallery = false
    var galleryPage: String?
    var stage: AppStage?
    var tab: MainTab?
    var pairingStep: String?
    var resetsOnboarding = false

    init(arguments: [String]) {
        for argument in arguments {
            if argument == "--gallery" { showsGallery = true }
            if let value = Self.value(of: "--gallery", in: argument) {
                showsGallery = true
                galleryPage = value
            }
            if argument == "--reset-onboarding" { resetsOnboarding = true }
            if let value = Self.value(of: "--stage", in: argument) { stage = AppStage(rawValue: value) }
            if let value = Self.value(of: "--pairing-step", in: argument) { pairingStep = value }
            if let value = Self.value(of: "--tab", in: argument) { tab = MainTab(rawValue: value) }
        }
    }

    static var current: LaunchOptions {
        #if DEBUG
        LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        #else
        LaunchOptions(arguments: [])
        #endif
    }

    private static func value(of name: String, in argument: String) -> String? {
        let prefix = name + "="
        return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
    }
}
