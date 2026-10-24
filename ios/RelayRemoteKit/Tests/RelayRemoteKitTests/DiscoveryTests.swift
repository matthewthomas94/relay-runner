import Network
import XCTest
@testable import RelayRemoteKit

final class DiscoveryTests: XCTestCase {
    func testStoredAddressesPutTailscaleFirstThenLANThenLocalNames() {
        let mac = PairedMac(deviceID: "phone-1", deviceName: "iPhone", user: "me",
                            hosts: ["Mac.local", "192.168.1.20", "10.0.0.4", "100.101.102.103"], port: 2222,
                            hostKeyFingerprints: [Fixtures.hostPin])
        XCTAssertEqual(MacEndpointResolver.addressEndpoints(for: mac), [
            .hostPort(host: "100.101.102.103", port: 2222),
            .hostPort(host: "192.168.1.20", port: 2222),
            .hostPort(host: "10.0.0.4", port: 2222),
            .hostPort(host: "Mac.local", port: 2222),
        ])
    }

    func testTailscaleRecognition() {
        for host in ["100.64.0.1", "100.127.255.254", "mac.tail1234.ts.net", "fd7a:115c:a1e0::1"] {
            XCTAssertTrue(MacEndpointResolver.isTailscale(host), host)
        }
        for host in ["100.63.0.1", "100.128.0.1", "192.168.1.20", "Mac.local", "10.0.0.1"] {
            XCTAssertFalse(MacEndpointResolver.isTailscale(host), host)
        }
    }

    func testBonjourResultsAreFilteredToThePairedHostName() {
        XCTAssertTrue(BonjourSSHBrowser.matches(hostTarget: "Matthews-MacBook-Pro.local.", pairedHost: "Matthews-MacBook-Pro.local"))
        XCTAssertTrue(BonjourSSHBrowser.matches(hostTarget: "matthews-macbook-pro.local", pairedHost: "Matthews-MacBook-Pro.local"))
        XCTAssertFalse(BonjourSSHBrowser.matches(hostTarget: "Other-Mac.local.", pairedHost: "Matthews-MacBook-Pro.local"))
        XCTAssertFalse(BonjourSSHBrowser.matches(hostTarget: "", pairedHost: ""))
    }

    func testBonjourNameComesFromTheStoredHosts() {
        let mac = PairedMac(deviceID: "p", deviceName: "i", user: "me", hosts: ["192.168.1.20", "Mac.local"], port: 22,
                            hostKeyFingerprints: [Fixtures.hostPin])
        XCTAssertEqual(mac.bonjourHostName, "Mac.local")
    }
}
