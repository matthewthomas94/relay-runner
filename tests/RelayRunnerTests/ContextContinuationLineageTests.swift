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
        XCTAssertEqual(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [record, later]]), .typed)
    }

    // RR-512: a typed turn's MCP calls must not inherit the last claimed voice
    // command, or the daemon refuses the typed dispatch under its authorization.
    func testTypedTurnAfterVoiceTurnNeverInheritsTheClaimedVoiceCommand() {
        let environment = ["RELAY_PROVIDER_SESSION_ID": "destination", "RELAY_APP_SESSION_ID": "app", "RELAY_RECOVERY_GENERATION": "generation", "RELAY_FOREGROUND_GATE_HANDLE": "gate"]
        let binding: [String: Any] = ["native_session_id": "native"]
        let owner: [String: Any] = ["provider_session_id": "destination", "session_id": "native", "app_session_id": "app", "recovery_generation": "generation", "foreground_gate_handle": "gate"]
        let voice = owner.merging(["created_at": 10.0, "state": "completed", "relay_command_seq": 375, "relay_command_id": "voice-375", "intent_id": "voice-375:item:1"]) { $1 }
        let typed = owner.merging(["created_at": 11.0, "state": "active", "origin": "manual", "manual_submission_id": "0df2d094"]) { $1 }
        XCTAssertEqual(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [voice, typed]]), .typed)
        // While the voice turn is newest, the claim file stays the authority.
        XCTAssertNil(contextContinuationLineage(environment: environment, binding: binding, projection: ["records": [typed.merging(["created_at": 9.0]) { $1 }, voice]]))
    }
}
