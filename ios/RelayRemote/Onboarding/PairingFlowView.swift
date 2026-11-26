import SwiftUI

/// Pairing (12–14): start, scan, check the fingerprint. A placeholder until
/// RR-539 that still pairs, through the existing `PairingView`. It finishes
/// as soon as the phone is paired.
struct PairingFlowView: View {
    let model: AppModel
    let onFinished: () -> Void

    @State private var showingPairing = false

    var body: some View {
        OnboardingHeroLayout(
            hero: "Pairing",
            action: OnboardingAction(title: "Pair with your Mac", icon: .qrCode) { showingPairing = true }
        ) {
            EmptyView()
        } secondary: {
            #if DEBUG
            // Lets the placeholders be walked on a simulator with no Mac.
            Button("Continue without pairing", action: onFinished)
                .buttonStyle(RelayButtonStyle(role: .secondary, fullWidth: true))
            #endif
        }
        .sheet(isPresented: $showingPairing) {
            NavigationStack { PairingView(model: model) }
        }
        .onChange(of: model.paired != nil) { _, paired in
            guard paired else { return }
            showingPairing = false
            onFinished()
        }
    }
}
