import SwiftUI

/// Agents (21–25): the selected agent's chat, dock and agent tabs. A
/// placeholder until RR-540 that hosts the existing debug screen, so the
/// app stays usable.
struct AgentsTabView: View {
    let model: AppModel

    var body: some View {
        if let session = model.session, let mac = model.paired {
            NavigationStack {
                DebugView(model: model, session: session, mac: mac)
            }
        } else {
            TabPlaceholder(title: "Agents", detail: "Pair with your Mac to talk to its agents.")
        }
    }
}

/// A tab's placeholder body: its name and one line under it.
struct TabPlaceholder: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Text(title).relayTextStyle(.titleL).foregroundStyle(RelayColor.neutral10)
            if let detail {
                Text(detail).relayTextStyle(.body).foregroundStyle(RelayColor.neutral7)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
