# RR-93 Notch Status Verification

Manual checks for a Mac display with a camera notch:

- Start a Relay Runner session from the menu bar or `/relay-bridge`; the compact Relay Runner icon should slide out just to the right of the notch and remain below the menu-bar strip while the session is active.
- End the session; the icon should retract and disappear, matching the tray icon returning to its inactive asset.
- With an external non-notched display attached, the icon should stay on the display that reports AppKit's notch `auxiliaryTopRightArea`; non-notched displays should not grow a detached fallback badge.
- Confirm the existing menu bar icon and menu still open and behave normally throughout the session.
