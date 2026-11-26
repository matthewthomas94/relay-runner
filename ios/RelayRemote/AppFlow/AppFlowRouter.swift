import SwiftUI

/// The app's root: picks the stage at launch, moves through onboarding, and
/// sends the user back to pairing when they forget the Mac. Each stage is its
/// own view in its own file; this file only routes between them.
struct AppFlowRouter: View {
    let model: AppModel
    var progress = OnboardingProgress()
    var launch = LaunchOptions.current

    @State private var stage: AppStage?

    var body: some View {
        ZStack {
            RelayColor.neutral1.ignoresSafeArea()
            AppGlowLayer(model: model)
            if launch.showsGallery {
                galleryOrApp
            } else if let stage {
                RelaySwap(stage) { stageView($0) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: start)
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
        case .permissions: PermissionsFlowView(onFinished: advance)
        case .pairing: PairingFlowView(model: model, onFinished: advance, initialStep: launch.pairingStep)
        case .tutorial: TutorialView(model: model, onFinished: advance)
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
        if current == .tutorial { progress.isFinished = true }
        stage = AppFlow.stage(after: current, onboardingFinished: progress.isFinished)
    }
}
