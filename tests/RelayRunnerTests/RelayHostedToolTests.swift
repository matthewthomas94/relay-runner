import XCTest
@testable import relay_runner

final class RelayHostedToolTests: XCTestCase {
    func testUnknownHostedToolReturnsStructuredFailure() async {
        let result = await RelayHostedTool.perform(tool: "unknown_tool", arguments: [:])

        switch result {
        case .success:
            XCTFail("Unknown hosted tools should fail.")
        case .failure(let message):
            XCTAssertTrue(message.contains("does not host a tool named 'unknown_tool'"))
        }
    }
}
