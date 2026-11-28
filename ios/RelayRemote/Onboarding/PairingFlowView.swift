import AVFoundation
import SwiftUI

/// Pairing (12–14): start, scan, check the fingerprint. The steps are driven
/// by `PairingFlowModel`; the pairing itself is `AppModel.pair(code:)`.
/// There is no Skip: the app can do nothing until it is paired.
struct PairingFlowView: View {
    @State private var flow: PairingFlowModel

    init(model: AppModel, onFinished: @escaping () -> Void, initialStep: String? = nil) {
        let created = PairingFlowModel(pairer: { code in
            await model.pair(code: code)
            if model.paired != nil { return nil }
            if case .failed(let message) = model.pairingState { return message }
            return "Pairing did not finish."
        }, onFinished: onFinished)
        #if DEBUG
        PairingDebug.open(initialStep, on: created)
        #endif
        _flow = State(initialValue: created)
    }

    var body: some View {
        PairingStepsView(flow: flow)
    }
}

private struct PairingStepsView: View {
    let flow: PairingFlowModel

    /// Pairing steps swap like onboarding stages (RR-553; they used to cut):
    /// the old step fades out with a light blur, then the new one fades in.
    var body: some View {
        ZStack {
            step
                .id(stepKey)
                .transition(.relayStageSwap)
        }
        .animation(RelayMotion.swap, value: stepKey)
    }

    /// Which step shows, ignoring the check step's details.
    private var stepKey: Int {
        switch flow.step {
        case .start: 0
        case .scan: 1
        case .check: 2
        }
    }

    @ViewBuilder
    private var step: some View {
        switch flow.step {
        case .start:
            OnboardingHeroLayout(
                hero: "Now let's pair\nwith your Mac",
                action: OnboardingAction(title: "Scan pairing code", icon: .qrCode, perform: flow.beginScan),
                accessory: {
                Text(flow.notice ?? "Relay Runner › Settings › Relay Remote")
                    .relayTextStyle(.body)
                    .foregroundStyle(RelayColor.neutral7)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, RelayMetrics.screenMargin)
            })
        case .scan:
            ScanStepView(flow: flow)
        case .check(let info):
            CheckStepView(flow: flow, info: info)
        }
    }
}

private struct ScanStepView: View {
    let flow: PairingFlowModel
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        || AVCaptureDevice.authorizationStatus(for: .video) == .restricted

    var body: some View {
        OnboardingHeroLayout(
            hero: "Scan the code on your Mac",
            action: OnboardingAction(title: "Paste code", icon: .clipboardPaste, role: .secondary) {
                flow.submit(UIPasteboard.general.string ?? "")
            },
            accessory: {
            VStack(spacing: 16) {
                Viewfinder(flow: flow, cameraDenied: cameraDenied)
                if cameraDenied {
                    line("Allow the camera in Settings › Relay Remote, or paste the code.")
                } else if let error = flow.scanError {
                    line(error)
                }
            }
            })
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .relayTextStyle(.body)
            .foregroundStyle(RelayColor.neutral7)
            .multilineTextAlignment(.center)
            .padding(.horizontal, RelayMetrics.screenMargin)
    }
}

/// The 280 pt camera viewfinder with corner brackets. Where there is no
/// camera (the simulator) or it is denied, it shows the empty frame.
private struct Viewfinder: View {
    let flow: PairingFlowModel
    let cameraDenied: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [RelayColor.neutral4, RelayColor.neutral2],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            if QRScannerView.isAvailable, !cameraDenied {
                QRScannerView(onCode: flow.submit)
                    .id(flow.scanAttempt)
                    .clipShape(shape)
            }
            Brackets().padding(32)
        }
        .frame(width: 280, height: 280)
        .accessibilityLabel("Camera viewfinder")
    }
}

private struct Brackets: View {
    var body: some View {
        GeometryReader { proxy in
            let arm: CGFloat = 40
            let size = proxy.size
            Path { path in
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1),
                                       (0, size.height, 1, -1), (size.width, size.height, -1, -1)] {
                    path.move(to: CGPoint(x: x + dx * arm, y: y))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x, y: y + dy * arm))
                }
            }
            .stroke(RelayColor.neutral10, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

private struct CheckStepView: View {
    let flow: PairingFlowModel
    let info: PairingCheckInfo

    var body: some View {
        OnboardingHeroLayout(
            hero: "Check it matches your Mac",
            action: OnboardingAction(title: "Cancel", role: .secondary, perform: flow.cancel),
            accessory: {
            VStack(spacing: 12) {
                macCard
                waitingCard
            }
            .padding(.horizontal, RelayMetrics.screenMargin)
        })
    }

    private var macCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LucideImage(.laptop, size: 24)
                    .frame(width: 40, height: 40)
                    .background(RelayColor.neutral4, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.macName).relayTextStyle(.cardTitle)
                    Text(info.detail).relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                }
            }
            Divider().overlay(RelayColor.neutral4)
            Text("Mac fingerprint").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
            HStack(spacing: 8) {
                ForEach(info.fingerprintGroups, id: \.self) { group in
                    Text(group)
                        .relayTextStyle(.titleL)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(RelayColor.neutral1, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(RelayColor.neutral4, lineWidth: 1))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Full host key").relayTextStyle(.caption).foregroundStyle(RelayColor.neutral7)
                Text(info.abbreviatedHostKey).relayTextStyle(.body)
            }
        }
        .foregroundStyle(RelayColor.neutral10)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .relayGlass(.panel)
    }

    private var waitingCard: some View {
        HStack(spacing: 12) {
            LucideImage(.refreshCw, size: 24).foregroundStyle(RelayColor.neutral7)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for your Mac").relayTextStyle(.cardTitle)
                if let expiresAt = flow.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text("Expires in \(Self.countdown(until: expiresAt, now: timeline.date))")
                            .relayTextStyle(.body)
                            .foregroundStyle(RelayColor.neutral7)
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(RelayColor.neutral10)
        .padding(16)
        .relayGlass(.panel)
    }

    /// "9:42": whole minutes and seconds left, rounded up, never below zero.
    static func countdown(until expiresAt: Date, now: Date) -> String {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}

#if DEBUG
/// `--pairing-step=scan|check` opens the flow on a step with sample data, for
/// simulator screenshots. The sample never pairs.
enum PairingDebug {
    @MainActor
    static func open(_ step: String?, on flow: PairingFlowModel) {
        switch step {
        case "scan": flow.beginScan()
        case "check": flow.showSampleCheck()
        default: break
        }
    }
}

extension PairingFlowModel {
    func showSampleCheck() {
        debugShow(.check(PairingCheckInfo(macName: "MacBook Pro", detail: "matthewthomas · MacBook-Pro.local",
                                          hostKey: "SHA256:K7QXM2PD9FHTkLm0pQrStUvWxYz1234567890abcdb81Q")),
                  expiresAt: Date().addingTimeInterval(9 * 60 + 42))
    }
}
#endif
