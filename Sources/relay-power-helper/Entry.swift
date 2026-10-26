import Foundation
import RelayPowerHelperProtocol

/// Relay Runner's Keep Awake power helper. launchd runs it as root from the app bundle
/// (Contents/Library/LaunchDaemons) once the user has allowed it in System Settings; it
/// starts on demand and at boot, and exits when idle.
@main
enum RelayPowerHelperEntry {
    private static var service: PowerHelperService?
    private static var listener: NSXPCListener?

    static func main() {
        guard geteuid() == 0 else {
            FileHandle.standardError.write(Data("relay-power-helper runs only as Relay Runner's launchd daemon.\n".utf8))
            exit(EX_NOPERM)
        }
        let service = PowerHelperService(core: PowerHelperCore(power: .live, record: .live), exit: { exit(0) })
        let listener = NSXPCListener(machServiceName: RelayPowerHelperIdentity.machServiceName)
        // Unsigned or differently signed clients are refused before any request is read.
        listener.setConnectionCodeSigningRequirement(RelayPowerHelperIdentity.appRequirement)
        listener.delegate = service
        self.service = service
        self.listener = listener
        service.start()
        listener.resume()
        dispatchMain()
    }
}
