import SwiftUI

@main
struct RelayRemoteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        NavigationStack {
            if let session = model.session, let mac = model.paired {
                DebugView(model: model, session: session, mac: mac)
            } else {
                PairingView(model: model)
            }
        }
    }
}
