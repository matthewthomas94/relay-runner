import XCTest
@testable import relay_runner

final class StateMachineAcknowledgementTests: XCTestCase {
    func testAcknowledgementStateUsesNotchOnlyPresentation() {
        let state = OverlayState.acknowledgement(text: "Got it: add tests.", autoDismiss: 3.25)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: state), "Acknowledged")
        XCTAssertEqual(NotchActivityLabelPlanner.labels(for: state), ["Acknowledged"])
        XCTAssertNil(state.particleTheme)
    }

    func testAdjacentVoiceAndResponseStatesKeepBottomOverlayPresentation() {
        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.listening), "Listening")
        XCTAssertEqual(OverlayState.listening.particleTheme, .stt)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.sessionReady), "Session ready")
        XCTAssertEqual(OverlayState.sessionReady.particleTheme, .tts)
        XCTAssertEqual(OverlayState.sessionReady.pillTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.processing), "Thinking")
        XCTAssertEqual(OverlayState.processing.particleTheme, .tts)

        let messageWaiting = OverlayState.messageWaiting(preview: "Done.")
        XCTAssertEqual(NotchActivityLabelPlanner.label(for: messageWaiting), "Response ready")
        XCTAssertEqual(messageWaiting.particleTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.preparing), "Preparing speech")
        XCTAssertEqual(OverlayState.preparing.particleTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.speaking), "Playing")
        XCTAssertEqual(OverlayState.speaking.particleTheme, .tts)

        XCTAssertEqual(NotchActivityLabelPlanner.label(for: OverlayState.speechFailed), "Speech unavailable")
        XCTAssertNil(OverlayState.speechFailed.particleTheme)
    }

    func testBottomPillStatusTitlesReuseNotchStatusLanguage() {
        let states: [(OverlayState, String)] = [
            (.listening, "Listening"),
            (.recording, "Listening"),
            (.sent, "Sending voice"),
            (.cancelled(.stt), "Recording cancelled"),
            (.cancelled(.tts), "Response cancelled"),
            (.processing, "Thinking"),
            (.sessionReady, "Session ready"),
            (.messageWaiting(preview: "Done."), "Response ready"),
            (.preparing, "Preparing speech"),
            (.speaking, "Playing"),
            (.speechFailed, "Speech unavailable"),
        ]

        for (state, title) in states {
            XCTAssertEqual(OverlayController.pillStatusTitle(for: state), title)
            XCTAssertEqual(
                OverlayController.pillStatusTitle(for: state),
                NotchActivityLabelPlanner.label(for: state)
            )
        }

        XCTAssertEqual(OverlayController.compactPillTitle(for: .listening, suffix: "..."), "Start speaking")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .recording, suffix: "..."), "Start speaking")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .sent), "Sending voice")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .cancelled(.tts)), "Response cancelled")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .processing, suffix: "\u{2026}"), "Thinking\u{2026}")
        XCTAssertEqual(
            OverlayController.compactPillTitle(for: .sessionReady),
            "Hello, what would you like to work on?"
        )
        XCTAssertEqual(OverlayController.compactPillTitle(for: .preparing, suffix: "..."), "Preparing speech...")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .messageWaiting(preview: nil), suffix: "..."), "Response ready...")
        XCTAssertEqual(OverlayController.compactPillTitle(for: .speaking, suffix: "..."), "Playing...")
        XCTAssertEqual(
            OverlayController.fullPillTitle(for: .recording, actionHint: "Press Caps Lock to stop and send"),
            "Press Caps Lock to stop and send"
        )
        XCTAssertEqual(
            OverlayController.fullPillTitle(for: .messageWaiting(preview: "Done."), actionHint: "Double tap Option to play"),
            "Double tap Option to play"
        )
        XCTAssertEqual(
            OverlayController.fullPillTitle(for: .speaking, actionHint: "Double tap Control to cancel"),
            "Double tap Control to cancel"
        )
        XCTAssertEqual(
            OverlayController.fullPillTitle(for: .idle, actionHint: "Ignored"),
            nil
        )
    }

    func testPreviewBodyIsRetainedAcrossResponsePlaybackStates() {
        XCTAssertEqual(
            OverlayController.previewBody(
                for: .messageWaiting(preview: "Ready response."),
                messagePreview: "Ready response.",
                messagePreviewEnabled: true
            ),
            "Ready response."
        )
        XCTAssertEqual(
            OverlayController.previewBody(
                for: .preparing,
                messagePreview: "Ready response.",
                messagePreviewEnabled: true
            ),
            "Ready response."
        )
        XCTAssertEqual(
            OverlayController.previewBody(
                for: .speaking,
                messagePreview: "Ready response.",
                messagePreviewEnabled: true
            ),
            "Ready response."
        )
        XCTAssertEqual(
            OverlayController.previewBody(
                for: .cancelled(.tts),
                messagePreview: "Ready response.",
                messagePreviewEnabled: true
            ),
            "Ready response."
        )
        XCTAssertEqual(
            OverlayController.previewBody(
                for: .messageWaiting(preview: "Ready response."),
                messagePreview: "Ready response.",
                messagePreviewEnabled: false
            ),
            "Ready response."
        )
        XCTAssertNil(
            OverlayController.previewBody(
                for: .processing,
                messagePreview: "Ready response.",
                messagePreviewEnabled: true
            )
        )
    }

    func testOptionAcknowledgementDoesNotRegressWhileRetainedSpeechCommits() {
        let stateMachine = StateMachine()
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Authoritative result.",
            autoDismiss: nil
        )

        stateMachine.setPlaybackRequested()
        XCTAssertEqual(stateMachine.state, .preparing)

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Authoritative result.",
            autoDismiss: nil
        )
        XCTAssertEqual(stateMachine.state, .preparing)

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "speaking",
            text: nil,
            autoDismiss: nil
        )
        XCTAssertEqual(stateMachine.state, .speaking)
    }

    func testSpeechFailureIsExplicitAndKeepsAuthoritativePreview() {
        let stateMachine = StateMachine()
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Authoritative result.",
            autoDismiss: nil
        )
        stateMachine.setPlaybackRequested()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "failed",
            text: nil,
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .speechFailed)
        XCTAssertEqual(stateMachine.messagePreview, "Authoritative result.")
        XCTAssertEqual(
            OverlayController.previewBody(
                for: stateMachine.state,
                messagePreview: stateMachine.messagePreview,
                messagePreviewEnabled: true
            ),
            "Authoritative result."
        )
    }

    func testSessionReadyIsIdleOnlyAndDismissesToIdle() {
        let stateMachine = StateMachine()

        stateMachine.showSessionReady()
        XCTAssertEqual(stateMachine.state, .sessionReady)

        stateMachine.dismissSessionReady()
        XCTAssertEqual(stateMachine.state, .idle)

        stateMachine.updateSTT(isRecording: true, partial: "")
        stateMachine.showSessionReady()
        XCTAssertEqual(stateMachine.state, .recording)

        stateMachine.updateSTT(isRecording: false, partial: "")
        stateMachine.dismissSent()
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Queued response.",
            autoDismiss: nil
        )
        stateMachine.showSessionReady()
        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Queued response."))

        stateMachine.setActionGlow(awaitingConfirmation: nil)
        stateMachine.showSessionReady()
        XCTAssertEqual(stateMachine.state, .actionGlow(awaitingConfirmation: nil))
    }

    func testBridgeAcknowledgementDuringSentIsDeferredUntilAfterSentWindowPlusPause() {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let stateMachine = StateMachine(now: { now })

        stateMachine.updateSTT(isRecording: true, partial: "hello")
        stateMachine.updateSTT(isRecording: false, partial: "")
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: add tests.",
            autoDismiss: 3.25
        )

        XCTAssertEqual(stateMachine.state, .sent)

        now = now.addingTimeInterval(StateMachine.sentAutoDismissDuration)
        stateMachine.dismissSent()
        stateMachine.promotePendingAcknowledgementIfReady()
        XCTAssertEqual(stateMachine.state, .idle)

        now = now.addingTimeInterval(StateMachine.acknowledgementDelayAfterSent - 0.01)
        stateMachine.promotePendingAcknowledgementIfReady()
        XCTAssertEqual(stateMachine.state, .idle)

        now = now.addingTimeInterval(0.01)
        stateMachine.promotePendingAcknowledgementIfReady()

        XCTAssertEqual(
            stateMachine.state,
            .acknowledgement(text: "Got it: add tests.", autoDismiss: 3.25)
        )
    }

    func testBridgeAcknowledgementUsesExplicitStateAndDismissesToIdle() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: add tests.",
            autoDismiss: 3.25
        )

        guard case .acknowledgement(let text, let autoDismiss) = stateMachine.state else {
            return XCTFail("Expected acknowledgement state")
        }
        XCTAssertEqual(text, "Got it: add tests.")
        XCTAssertEqual(autoDismiss, 3.25)

        stateMachine.dismissAcknowledgement()

        XCTAssertEqual(stateMachine.state, .idle)
    }

    func testBridgeAcknowledgementFallsBackWhenTextIsBlank() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .acknowledgement(text: "Got it. I'm on it.", autoDismiss: 3.0))
    }

    func testBridgeAcknowledgementDoesNotReplaceSubstantiveTTSResponse() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Here is the detailed response.",
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: late acknowledgement.",
            autoDismiss: 3.0
        )

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Here is the detailed response."))
    }

    func testDelayedAcknowledgementIsSuppressedWhenSubstantiveTTSArrivesFirst() {
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let stateMachine = StateMachine(now: { now })

        stateMachine.updateSTT(isRecording: true, partial: "hello")
        stateMachine.updateSTT(isRecording: false, partial: "")
        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "acknowledgement",
            text: "Got it: late acknowledgement.",
            autoDismiss: 3.0
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Here is the detailed response.",
            autoDismiss: nil
        )

        now = now.addingTimeInterval(
            StateMachine.sentAutoDismissDuration + StateMachine.acknowledgementDelayAfterSent
        )
        stateMachine.promotePendingAcknowledgementIfReady()

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Here is the detailed response."))
    }

    func testPreparingEventCanRestoreTranscriptPreviewAfterIdle() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Queued reply",
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "idle",
            text: nil,
            autoDismiss: nil
        )
        XCTAssertNil(stateMachine.messagePreview)

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "preparing",
            text: "Queued reply",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .preparing)
        XCTAssertEqual(stateMachine.messagePreview, "Queued reply")
    }

    func testSpeakingEventCanRestoreTranscriptPreviewWithoutMessageWaiting() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "speaking",
            text: "Previously spoken reply",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .speaking)
        XCTAssertEqual(stateMachine.messagePreview, "Previously spoken reply")
    }

    func testBlankWaitingAndPlaybackEventsPreserveAvailableResponsePreview() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Completed response.",
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Completed response."))
        XCTAssertEqual(stateMachine.messagePreview, "Completed response.")

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "preparing",
            text: nil,
            autoDismiss: nil
        )
        XCTAssertEqual(stateMachine.state, .preparing)
        XCTAssertEqual(stateMachine.messagePreview, "Completed response.")

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "speaking",
            text: "",
            autoDismiss: nil
        )
        XCTAssertEqual(stateMachine.state, .speaking)
        XCTAssertEqual(stateMachine.messagePreview, "Completed response.")

        stateMachine.setCancelled()
        XCTAssertEqual(stateMachine.state, .cancelled(.tts))
        XCTAssertEqual(stateMachine.messagePreview, "Completed response.")

        stateMachine.dismissSent()
        XCTAssertEqual(stateMachine.state, .idle)
        XCTAssertNil(stateMachine.messagePreview)
    }

    func testConsecutiveResponsesUseFreshWaitingPreviewAfterIdle() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "First response.",
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "idle",
            text: nil,
            autoDismiss: nil
        )
        XCTAssertNil(stateMachine.messagePreview)

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: nil,
            autoDismiss: nil
        )
        XCTAssertEqual(stateMachine.state, .idle)
        XCTAssertNil(stateMachine.messagePreview)

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "Second response.",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .messageWaiting(preview: "Second response."))
        XCTAssertEqual(stateMachine.messagePreview, "Second response.")
    }

    func testBlankWaitingEventDoesNotReplaceCompactProcessingState() {
        let stateMachine = StateMachine()

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "processing",
            text: nil,
            autoDismiss: nil
        )
        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "message_waiting",
            text: "  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .processing)
        XCTAssertNil(stateMachine.messagePreview)
    }

    func testBridgeWorkingEventStoresFreshSanitizedProgressWithoutChangingVisibleState() {
        var now = Date(timeIntervalSince1970: 1_000)
        let stateMachine = StateMachine(now: { now })

        stateMachine.handleServiceEvent(
            source: "bridge",
            newState: "working",
            text: "  First pass found 102 SKILL.md files.\nNarrowing the audit now.  ",
            autoDismiss: nil
        )

        XCTAssertEqual(stateMachine.state, .idle)
        XCTAssertEqual(
            stateMachine.workingProgress,
            "First pass found 102 SKILL.md files. Narrowing the audit now."
        )
        XCTAssertEqual(
            stateMachine.currentWorkingProgress(now: now),
            "First pass found 102 SKILL.md files. Narrowing the audit now."
        )

        now = now.addingTimeInterval(StateMachine.workingProgressFreshnessDuration + 1)
        XCTAssertNil(stateMachine.currentWorkingProgress(now: now))

        stateMachine.handleServiceEvent(
            source: "tts",
            newState: "preparing",
            text: nil,
            autoDismiss: nil
        )

        XCTAssertNil(stateMachine.workingProgress)
    }

    func testBridgeWorkingEventSuppressesRawPrivateAndIdleMonitoringText() {
        let stateMachine = StateMachine()

        for text in [
            "git status --short",
            "Reading hidden reasoning transcript",
            "Relay mode waiting for voice input",
            "Heartbeat refresh while monitoring bridge",
        ] {
            stateMachine.handleServiceEvent(
                source: "bridge",
                newState: "working",
                text: text,
                autoDismiss: nil
            )

            XCTAssertNil(stateMachine.workingProgress, text)
            XCTAssertNil(stateMachine.currentWorkingProgress(), text)
        }
    }
}
