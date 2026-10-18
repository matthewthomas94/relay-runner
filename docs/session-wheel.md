# Session wheel

A short, stationary **four-finger trackpad tap** toggles the wheel at the pointer.
The menu bar also has **Show Session Wheel**. The wheel remains open after the
fingers lift; selection requires a click. Tap again, click outside, click the
center, or press Escape to dismiss. Near a display edge, the complete wheel and
its outer controls move inside the usable screen area.

The six slots show live project sessions, including general-tasks. Sessions keep
their positions as other sessions start or stop. Relay's existing four-session
limit still applies.

- Hover a session to reveal three controls on the arc just outside its slot:
  **Play / Replay message**, **Record / Stop recording**, and **Stop session**.
- Click a session itself to switch voice to it. The terminal stays where it is;
  the notch briefly reports the switch.
- Click an empty slot to enter the project wheel. Click an available registered
  project to start its session without opening the Workspace. The center or Escape
  returns to sessions; paging arrows show more than six projects.
- Playback uses that session's latest stored reply. Recording is pinned to the
  chosen session even if focus changes before capture starts. An existing
  recording can be stopped only from its owning session. Stop session cancels
  that session's recording before ending it.
- Unavailable projects, absent replies, and unavailable recording controls are
  disabled. The project wheel explains session-cap, launch, and note-capture
  restrictions. Controls are also exposed as VoiceOver actions on session slots.

The UI uses the existing black surfaces, Bai Jamjuree typography, neutral hover
fills, subtle selection borders, and red stop treatment. The 34-point-deep outer
controls follow the wheel's tangent, keeping their icons and labels upright on
the lower half, with compact labels and icons padded inside each segment. Main
wedges use Relay's 14-point card corners; submenu segments use its 6-point control
corners. Submenus, project pages, and changing center labels use Relay's
shared entry, exit, and replacement transitions, including Reduce Motion and
increased contrast handling. Project navigation rearms pointer hover so a double-click on
an empty slot cannot launch a project in the same position.

## Input and lifecycle

Global trackpad contacts are read through the optional macOS
`MultitouchSupport` framework, loaded dynamically. If its required symbols are
unavailable, the menu-bar entry remains usable. The reader rejects swipes,
pinches, holds, clicks, extra fingers, and invalid contact records. It does not
intercept normal OS gestures. Trackpads are rediscovered after sleep, user-session
changes, and connection changes. App shutdown and update relaunch stop the reader;
sleep and screen changes dismiss an open wheel.

The reference behavior was inspected in
[Vorssaint at commit 5d1ffa07](https://github.com/vorssaint/vorssaint-utils/tree/5d1ffa07c83665c83123fdf734a70843cd1f8771/Sources/Vorssaint/Services/RadialMenu)
and its adjacent MiddleClick service. Relay's implementation is written for its
own session lifecycle and design system; no Vorssaint source files are vendored.

## Verification

Run the focused checks with:

```sh
env -u SDKROOT swift test --filter 'FourFingerTapGestureTests|SessionWheelTests|VoiceReplyBadgeTests|STT|VoiceBridgeFocusTests|CapsLockGestureTests'
```

Set `RELAY_WHEEL_RENDER_DIR` to an output directory to export SwiftUI previews
from `SessionWheelTests.testWheelRendering`. Tests use fake capture and temporary
spools; they do not open the microphone or send commands to live sessions.

Installed-app checks still require a physical trackpad and live sessions: open
and dismiss across displays, reject swipes and pinches, navigate to every outer
control, start a project from a later page, replay a background session's reply,
record and send to each provider, stop one session while the others continue, and
repeat after sleep or reconnecting a trackpad. Automated tests and rendered
fixtures do not establish those hardware and audible outcomes.
