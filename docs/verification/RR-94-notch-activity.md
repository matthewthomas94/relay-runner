# RR-94 notch activity manual verification

Manual checks for a Mac display with a camera notch:

- Start a Relay Runner session from the menu bar or `/relay-bridge`; the right status icon should still slide out as in RR-93, and no left activity capsule should be visible while the session is idle.
- Start recording. The black activity capsule should pull out from the left side of the notch and show concise copy such as "Listening"; it should retract when the state returns to idle.
- Send a prompt and let a response play. The capsule should show short provider-neutral states such as "Sending voice", "Thinking", "Response ready", "Preparing speech", and "Speaking response" as those events are available.
- Dispatch active Codex and Claude workers. Both providers should feed the same concise worker wording through the run-index activity model, such as "Dispatching worker", "Running tests", or "Editing files"; provider names and raw commands should not appear in the capsule.
- With multiple labels available, the capsule should carousel in the fixed left-side frame without resizing or shifting menu bar items.
- Enable Reduce Motion in macOS Accessibility settings; the capsule should still appear and retract, but panel slide durations should collapse to zero.
- On an external non-notched display, no detached left activity badge should appear. With multiple displays, the capsule should stay on the display that reports AppKit notch auxiliary areas.
- With Figma (or another app with a long menu bar) frontmost, let the session work: the capsule stays within about 180 pt left of the notch and never covers a menu item. Hover the glyph and the full progress text appears; moving away returns to the short label.
