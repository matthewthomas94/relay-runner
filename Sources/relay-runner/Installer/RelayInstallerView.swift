import AppKit
import SwiftUI

@MainActor
final class RelayInstallerWindowController {
    static let shared = RelayInstallerWindowController()

    private var windowController: NSWindowController?

    func show(context: RelayInstallerContext) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
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

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let wc = NSWindowController(window: window)
        windowController = wc
        wc.showWindow(nil)
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
                    NSApplication.shared.terminate(nil)
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

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: context.sourceBundleURL.path))
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(radius: 8, y: 3)

            VStack(spacing: 8) {
                Text("Install Relay Runner")
                    .font(.title2.bold())
                Text(model.statusText)
                    .font(.headline)
                Text(model.detailText)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: model.progress)
                .frame(width: 320)

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 360)

                HStack {
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                    Button("Retry") { model.retry(context: context) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(36)
        .frame(width: 460, height: 360)
        .task {
            model.start(context: context)
        }
    }
}
