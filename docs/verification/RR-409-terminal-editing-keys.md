# RR-409: Terminal editing keys in the session prompt

## Root cause and fix

Reviewed source merge `37bd397a2b942c05c0ac8041edbe9eed7f9d3929` (worker run 212).

- **Root cause.** SwiftTerm 1.15 routes Shift-arrows, non-Meta (right) Option-Delete and Cmd-Delete through `interpretKeyEvents` to `moveLeftAndModifySelection:`, `deleteWordBackward:` and `deleteToBeginningOfLine:`, then drops them as "Unhandle selector", so the hosted CLI received nothing. Right Option-arrows likewise hit the unhandled `moveWordLeft:` outside the app's key monitor. In Kitty mode SwiftTerm encodes Cmd as Super (`CSI 1;9D`, and Cmd-Delete as `f`), which Codex 0.162 ignores. Codex also ignores all Shift-modified arrows, so they looked dead.
- **Not reproduced.** Dead Cmd/Option-arrows for the left Option key in raw mode. The existing local monitor delivers those in a real non-activating panel and across host reparenting, and 0.4.65 already contains it.
- **Fix.** `RelayTerminalView.editingKey` encodes Cmd/Option arrows, Option/Cmd-Delete, Fn-Option-Delete and Shift / Shift-Option / Shift-Cmd arrows for either Option key. It sends the Kitty forms when the CLI has negotiated keyboard flags and readline bytes otherwise. The monitor swallows the matching keyUp, so no orphan Kitty release is sent. Codex sessions drop Shift and send plain movement.
- **Unsent-prompt tracker.** `ESC DEL`, Ctrl-W and Kitty alt-backspace delete a word. `ESC d` and `CSI 3;m~` are edits. Ctrl-U, Kitty `117;5u` and `127;9u` clear the line. Meta/Super navigation is not prompt text.

The supported keys and their byte sequences are listed in `docs/providers.md` under "Embedded terminal editing keys".

## Per-provider results

A PTY harness answered terminal queries the way SwiftTerm does (run 212).

| Provider | Keyboard protocol | Result |
| --- | --- | --- |
| Claude Code 2.1.302 | Flags 0 (raw bytes) | All of the table's bytes work. Shift-arrows `CSI 1;2D` / `1;4D` / `1;10D` move by character, word and line, but Claude has no prompt selection of its own. |
| Codex 0.162.1 | Kitty flags 7 | Kitty `97;5u`, `101;5u`, `1;3D` / `1;3C`, `127;3u`, `117;5u` and `100;3u` all work. Codex ignores Shift-arrows, so the app sends unshifted movement: the cursor moves, but Codex cannot select. |

## Terminal-drawn prompt selection

Follow-up commit `b7c4c25286c2c49beb8a1aa5bbe8a4a6ca857ebe` adds `Sources/relay-runner/Terminal/PromptSelection.swift`. Neither CLI selects on Shift-arrows, so the embedded terminal:

- reads the prompt back from the screen (Claude Code's ruled input box, Codex's `›` prompt);
- draws the selection itself;
- drives the provider's cursor with plain arrow presses.

While text is selected:

- Cmd-C copies it.
- Delete deletes it.
- Typing or pasting replaces it.
- Left / Right collapse it.

When the prompt cannot be read exactly, the RR-409 editing-key bytes are sent unchanged. That happens with chips, scrollback, voice-held input, or a provider that does not follow the presses.

## Automated checks — 2026-10-18 (close-out run 230)

Run on worktree HEAD `604c02db`, which contains both commits above.

- `swift build`: passed.
- `swift test --filter` for the classes in `EmbeddedTerminalSessionTests.swift` and `PromptSelectionTests.swift`:
  - `RelayTerminalEditingKeyEventPathTests`: 1/1 passed (ran, not skipped).
  - `RelayTerminalInputTrackerTests`: 9/9 passed.
  - `RelayTerminalViewInputOriginTests`: 18/18 passed.
  - `RelayPromptSelectionTests`: 10/10 passed.
  - `RelayPromptLayoutTests`: 7/7 passed.
  - `EmbeddedTerminalSessionTests`: 21/21 passed in two separate runs. In a third, combined run, `testAppOwnedDeliveryWaitsForStableProviderPTYForBothProviders` failed one assertion. That test uses fixed wall-clock waits around a live PTY and is not part of the RR-409 key path. It then passed 3/3 when rerun in isolation.

## User acceptance — 2026-10-18

The user manually tested an installed build containing the fix and confirmed the editing keys work. That satisfies the installed-app verification gate, so RR-409 can close as done.
