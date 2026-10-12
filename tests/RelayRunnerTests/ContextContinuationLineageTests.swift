import XCTest
@testable import relay_orchestrator_mcp

final class ContextContinuationLineageTests: XCTestCase {
    func testExactDestinationPreservesVoiceParentEvenAfterCancellationAndTypedNeverBorrowsVoice() {
        let environment = ["RELAY_PROVIDER_SESSION_ID": "destination", "RELAY_APP_SESSION_ID": "app", "RELAY_RECOVERY_GENERATION": "generation", "RELAY_FOREGROUND_GATE_HANDLE": "gate"]
        let binding: [String: Any] = ["native_session_id": "native"]
        var record: [String: Any] = ["provider_session_id": "destination", "session_id": "native", "app_session_id": "app", "recovery_generation": "generation", "foreground_gate_handle": "gate", "manual_submission_id": "continuation-source-destination", "created_at": 20.0, "origin": "manual", "state": "cancelled", "relay_command_seq": 42, "relay_command_id": "original-voice", "intent_id": "original-intent"]
        XCTAssertEqual(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [record]]), .voice(seq: 42, id: "original-voice", intentID: "original-intent"))
        for field in ["provider_session_id", "session_id", "app_session_id", "recovery_generation", "foreground_gate_handle"] {
            var foreign = record; foreign[field] = "foreign"
            XCTAssertNil(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [foreign]]))
        }
        record.removeValue(forKey: "relay_command_seq"); record.removeValue(forKey: "relay_command_id"); record.removeValue(forKey: "intent_id")
        XCTAssertEqual(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [record]]), .typed)
        var later = record; later["created_at"] = 21.0; later["manual_submission_id"] = "normal-manual"
        XCTAssertNil(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [record, later]]))
    }
}
