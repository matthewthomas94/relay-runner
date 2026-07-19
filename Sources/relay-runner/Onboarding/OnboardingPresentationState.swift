import SwiftUI

struct OnboardingDetailPresentation: Equatable {
    let title: String
    let subtitle: String
    let progress: String?

    static let inactive = OnboardingDetailPresentation(
        title: "Status",
        subtitle: "Permissions and runtime",
        progress: nil
    )
}

struct OnboardingFooterAction {
    enum Shortcut {
        case `default`
        case cancel
    }

    let title: String
    let systemImage: String?
    let prominence: SettingsActionButton.Prominence
    let isEnabled: Bool
    let accessibilityLabel: String?
    let helpText: String?
    let shortcut: Shortcut?
    let perform: () -> Void
}

@Observable
final class OnboardingPresentationState {
    private(set) var rootView: AnyView?
    private(set) var detail = OnboardingDetailPresentation.inactive
    private(set) var primaryAction: OnboardingFooterAction?
    private(set) var secondaryAction: OnboardingFooterAction?
    private(set) var contentVisible = true
    private(set) var presentationSerial = 0

    var isPresented: Bool {
        rootView != nil
    }

    func present(rootView: AnyView, initialDetail: OnboardingDetailPresentation) {
        self.rootView = rootView
        detail = initialDetail
        contentVisible = true
        presentationSerial += 1
    }

    func update(detail: OnboardingDetailPresentation) {
        self.detail = detail
    }

    func updateActions(primary: OnboardingFooterAction?, secondary: OnboardingFooterAction?) {
        primaryAction = primary
        secondaryAction = secondary
    }

    func setContentVisible(_ visible: Bool) {
        contentVisible = visible
    }

    func clear() {
        rootView = nil
        detail = .inactive
        primaryAction = nil
        secondaryAction = nil
        contentVisible = true
    }
}
