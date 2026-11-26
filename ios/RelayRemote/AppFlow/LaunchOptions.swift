import Foundation

/// Debug-only launch arguments that open the app on a given screen, for
/// simulator screenshots:
/// - `--gallery` shows the design-system reference gallery, and
///   `--gallery=<page>` opens it on one of its pages,
/// - `--stage=<splash|permissions|pairing|tutorial|app>` starts at a stage,
/// - `--pairing-step=<scan|check>` opens the pairing flow on a step,
/// - `--tab=<agents|workspace|settings>` opens the app on a tab,
/// - `--workspace-sample=<list|empty|error|unreachable|truncated>` fills the Workspace tab
///   with sample data instead of the Mac's,
/// - `--agents-sample=<ready|holding|playing|not-running|unreachable|long-draft>`
///   shows the Agents tab with sample data in one of its states (RR-540),
/// - `--tutorial-step=<basics|hold|release|play|stop|done>` shows a tutorial step with
///   sample data (RR-542),
/// - `--sample-settings` fills the Settings tab with sample data, unpaired,
/// - `--scroll-bottom` opens scrolling screens at their end,
/// - `--reset-onboarding` forgets that onboarding finished, as a fresh install.
/// Release builds ignore them.
struct LaunchOptions: Equatable {
    var showsGallery = false
    var galleryPage: String?
    var stage: AppStage?
    var tab: MainTab?
    var pairingStep: String?
    var workspaceSample: String?
    var agentsSample: String?
    var tutorialSample: String?
    var resetsOnboarding = false
    var sampleSettings = false
    var scrollsToBottom = false

    init(arguments: [String]) {
        for argument in arguments {
            if argument == "--gallery" { showsGallery = true }
            if let value = Self.value(of: "--gallery", in: argument) {
                showsGallery = true
                galleryPage = value
            }
            if argument == "--reset-onboarding" { resetsOnboarding = true }
            if argument == "--scroll-bottom" { scrollsToBottom = true }
            if argument == "--sample-settings" { sampleSettings = true }
            if let value = Self.value(of: "--stage", in: argument) { stage = AppStage(rawValue: value) }
            if let value = Self.value(of: "--pairing-step", in: argument) { pairingStep = value }
            if let value = Self.value(of: "--workspace-sample", in: argument) { workspaceSample = value }
            if let value = Self.value(of: "--tab", in: argument) { tab = MainTab(rawValue: value) }
            if let value = Self.value(of: "--agents-sample", in: argument) { agentsSample = value }
            if let value = Self.value(of: "--tutorial-step", in: argument) { tutorialSample = value }
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
