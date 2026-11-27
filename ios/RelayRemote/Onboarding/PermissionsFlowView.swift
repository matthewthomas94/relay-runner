import SwiftUI

/// Permissions (06–11): one step per permission, each a hero line, a button
/// naming the system prompt it raises ("Allow microphone"; "Continue" when the
/// permission was already answered and no prompt will show), and Skip.
struct PermissionsFlowView: View {
    let onFinished: () -> Void

    @State private var model: PermissionsFlowModel

    @MainActor
    init(model: PermissionsFlowModel? = nil, onFinished: @escaping () -> Void) {
        _model = State(initialValue: model ?? PermissionsFlowModel())
        self.onFinished = onFinished
    }

    var body: some View {
        Group {
            if let step = model.current {
                OnboardingHeroLayout(hero: step.hero, onSkip: { model.skip() },
                                     action: OnboardingAction(title: model.actionTitle) {
                                         Task { await model.grant() }
                                     })
            } else {
                Color.clear
            }
        }
        .task {
            await model.load(startingAt: LaunchOptions.current.permissionStep,
                             everyStep: OnboardingProgress().isReplaying)
        }
        .onChange(of: model.isLoaded && model.current == nil, initial: true) { _, finished in
            if finished { onFinished() }
        }
    }
}
