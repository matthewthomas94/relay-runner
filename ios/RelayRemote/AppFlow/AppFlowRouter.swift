import SwiftUI

/// The app's root: picks the stage at launch, moves through onboarding, and
/// sends the user back to pairing when they forget the Mac. Each stage is its
/// own view in its own file; this file only routes between them.
struct AppFlowRouter: View {
    let model: AppModel
    var progress = OnboardingProgress()
    var launch = LaunchOptions.current

    @State private var stage: AppStage?
    /// The permissions steps, loaded before their stage shows so its first
    /// frame already has the first step.
    @State private var permissions: PermissionsFlowModel?

    var body: some View {
        ZStack {
            RelayColor.neutral1.ignoresSafeArea()
            if stage == .app {
                RelayBackdrop().transition(.opacity.animation(RelayMotion.change))
            }
            // In the app the glow sits over the scrolling content and under
            // the glass, so `MainTabView` draws it (user, 2026-11-27).
            if launch.showsGallery || stage != .app {
                AppGlowLayer(model: model)
            }
            if launch.showsGallery {
                galleryOrApp
            } else if let stage {
                // Onboarding stages swap their hero line in place; the app
                // arrives with the desktop's page transition.
                stageView(stage)
                    .id(stage)
                    .transition(stage == .app ? .relayPage(direction: 1) : .relayStageSwap)
            }
        }
        .animation(RelayMotion.pageEnter, value: stage)
        .environment(\.micLevel, model.voice?.micLevel)
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
        // Testing: Settings › Redo onboarding walks it again from the splash.
        .onChange(of: model.onboardingReplayRequests) { stage = .splash }
        .onChange(of: model.paired != nil) { wasPaired, isPaired in
            // Forget this Mac: the app can do nothing until it pairs again.
            if wasPaired, !isPaired, stage == .app { stage = .pairing }
        }
    }

    @ViewBuilder
    private var galleryOrApp: some View {
        #if DEBUG
        DesignGalleryView(initialPage: launch.galleryPage.flatMap(GalleryPage.init(rawValue:)) ?? .type)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private func stageView(_ stage: AppStage) -> some View {
        switch stage {
        case .splash: SplashView(onFinished: advance)
        case .permissions: PermissionsFlowView(model: permissions, onFinished: advance)
        case .pairing: PairingFlowView(model: model, onFinished: advance, initialStep: launch.pairingStep)
        case .tutorial: TutorialView(model: model, onFinished: advance, sample: launch.tutorialSample)
        case .app:
            MainTabView(model: model, initialTab: launch.tab ?? (launch.ticketSample == nil ? .agents : .workspace),
                        workspaceSample: launch.workspaceSample ?? (launch.ticketSample == nil ? nil : "list"),
                        ticketSample: launch.ticketSample)
        }
    }

    private func start() {
        guard stage == nil else { return }
        model.bootstrap()
        if launch.resetsOnboarding { progress.isFinished = false }
        stage = launch.stage ?? AppFlow.initialStage(onboardingFinished: progress.isFinished,
                                                     paired: model.paired != nil)
    }

    private func advance() {
        guard let current = stage else { return }
        if current == .tutorial {
            progress.isFinished = true
            progress.isReplaying = false
        }
        var next = AppFlow.stage(after: current, onboardingFinished: progress.isFinished)
        // A replay keeps the pairing, so it goes from permissions to the tutorial.
        if next == .pairing, progress.isReplaying, model.paired != nil { next = .tutorial }
        guard next == .permissions else {
            stage = next
            return
        }
        let flow = PermissionsFlowModel()
        Task {
            await flow.load(startingAt: launch.permissionStep, everyStep: progress.isReplaying)
            permissions = flow
            stage = .permissions
        }
    }
}
