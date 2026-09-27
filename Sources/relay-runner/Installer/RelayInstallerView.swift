import AppKit
import SwiftUI

@MainActor
final class RelayInstallerWindowController {
    static let shared = RelayInstallerWindowController()

    private var windowController: NSWindowController?

    func show(context: RelayInstallerContext) {
        if let window = windowController?.window {
            RelayWindowMotion.present(window)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: RelayInstallerView(context: context))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Install Relay Runner"
        window.styleMask = [.titled]
        window.setContentSize(NSSize(width: 460, height: 360))
        window.center()
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let wc = NSWindowController(window: window)
        windowController = wc
        RelayWindowMotion.present(window)
    }

    /// Fades the installer window out before `completion` quits the app.
    func dismiss(completion: @escaping () -> Void) {
        guard let window = windowController?.window else {
            completion()
            return
        }
        RelayWindowMotion.dismiss(window, completion: completion)
    }
}

@MainActor
@Observable
final class RelayInstallerModel {
    enum Phase {
        case preparing
        case installing
        case launching
        case failed
    }

    var phase: Phase = .preparing
    var progress = 0.0
    var statusText = "Preparing Relay Runner..."
    var detailText = "Relay Runner will be installed in Applications."
    var errorText: String?

    private var started = false

    func start(context: RelayInstallerContext) {
        guard !started else { return }
        started = true
        let startedAt = Date()
        phase = .installing
        statusText = "Installing Relay Runner..."
        detailText = "Copying Relay Runner to Applications."

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try RelayBundleInstaller.install(
                    from: context.sourceBundleURL,
                    to: context.installedBundleURL
                ) { progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.update(progress)
                    }
                }

                let remainingDelay = RelayInstallerLaunch.remainingDelay(startedAt: startedAt)
                if remainingDelay > 0 {
                    let nanoseconds = UInt64(remainingDelay * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }

                DispatchQueue.main.async { [weak self] in
                    self?.launchInstalledApp(context.installedBundleURL)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.fail(error)
                }
            }
        }
    }

    func retry(context: RelayInstallerContext) {
        started = false
        errorText = nil
        progress = 0
        start(context: context)
    }

    private func update(_ installProgress: RelayInstallProgress) {
        progress = installProgress.fractionCompleted
        detailText = "Copying \(installProgress.currentItem)"
    }

    private func launchInstalledApp(_ installedBundleURL: URL) {
        phase = .launching
        progress = 1
        statusText = "Relay Runner installed."
        detailText = "Launching Relay Runner..."

        let configuration = RelayInstallerLaunch.openConfiguration()
        NSWorkspace.shared.openApplication(at: installedBundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    self.fail(error)
                } else {
                    RelayInstallerWindowController.shared.dismiss {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
    }

    private func fail(_ error: Error) {
        phase = .failed
        statusText = "Install failed."
        detailText = "Relay Runner was not installed."
        errorText = error.localizedDescription
    }
}

struct RelayInstallerView: View {
    let context: RelayInstallerContext
    @State private var model = RelayInstallerModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: context.sourceBundleURL.path))
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(radius: 8, y: 3)

            VStack(spacing: 8) {
                Text("Install Relay Runner")
                    .font(AppTypography.font(.appTitle))
                Text(model.statusText)
                    .font(AppTypography.font(.cardHeading))
                    .relayTextSwap(model.statusText, alignment: .center)
                // Per-file copy progress updates in place; the detail line
                // only crossfades when the install moves to a new phase.
                Text(model.detailText)
                    .foregroundStyle(.secondary)
                    .relayTextSwap(model.phase, alignment: .center)
            }

            ProgressView(value: model.progress)
                .frame(width: 320)
                .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.progress)

            if let errorText = model.errorText {
                Text(errorText)
                    .font(AppTypography.font(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)
                    .transition(.relayElement)

                HStack {
                    Button("Quit") {
                        RelayInstallerWindowController.shared.dismiss {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    Button("Retry") { model.retry(context: context) }
                        .keyboardShortcut(.defaultAction)
                }
                .transition(.relayElement)
            }
        }
        .animation(RelayMotion.change(reduceMotion: reduceMotion), value: model.errorText)
        .padding(36)
        .frame(width: 460, height: 360)
        .task {
            model.start(context: context)
        }
    }
}
