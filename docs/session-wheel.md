# Session wheel

A short, stationary **four-finger trackpad tap** toggles the wheel at the pointer.
The menu bar also has **Show Session Wheel**. The wheel remains open after the
fingers lift; selection requires a click. Tap again, click outside, or press Escape
to dismiss. Near a display edge, the complete wheel and
its outer controls move inside the usable screen area.

The six slots show live project sessions, including general-tasks. Sessions keep
their positions as other sessions start or stop. Relay's existing four-session
limit still applies.

- Click the session wheel's center to dismiss the wheel and toggle the Workspace:
  open it when hidden, or close it when already visible. Project wheels keep
  **Back** in the center; Escape still backs out or dismisses without toggling Workspace.
- Hover a session to reveal three controls on the arc just outside its slot:
  **Play / Stop playback / Replay message**, **Record / Stop recording**, and **Stop session**.
- All submenu actions keep the wheel open. Click **Stop recording** to send the
  message to that session; its controls stay available afterward. Ending a session
  frees its slot without closing the wheel.
- Click a session itself to switch voice to it. The terminal stays where it is;
  the notch briefly reports the switch.
- Click an empty slot to enter the project wheel. Click an available registered
  project to start its session without opening the Workspace. The center shows
  the Workspace's detail action text styling with a left-chevron icon beside **Back**.
  The entire center is the hover and click target. When projects overflow, the
  sixth segment becomes **More projects**, with an ellipsis icon, and opens the next nested wheel.
  Back or Escape returns one wheel at a time, then to sessions. Starting a project
  returns to the session wheel and keeps it open.
- Playback shows **Play message** for queued speech, **Stop playback** while
  preparing or playing, and **Replay message** when only replay history remains.
  State comes from the shared speech coordinator independently of notch recording
  presentation. Controls target the selected session without changing focus;
  stored unread replies play in order before replaying the latest reply.
  Recording is pinned to the
  chosen session even if focus changes before capture starts. An existing
  recording can be stopped only from its owning session. Stop session cancels
  that session's recording before ending it.
- Unavailable projects, absent replies, and unavailable recording controls are
  disabled. The project wheel's center tooltip explains session-cap, launch, and
  note-capture restrictions. Controls are also exposed as VoiceOver actions on
  session slots.

The UI uses the workspace cards' shared dark fills, hover and selection treatment,
and subtle borders, with Bai Jamjuree typography and red stop controls. The wheel has
no outer border. Segments use consistent 8-point spacing between their straight
edges, around the center and outer perimeter. The 34-point-deep outer
controls follow the wheel's tangent, keeping their icons and labels upright on
the lower half, with compact labels and icons padded inside each segment. Main
wedges use Relay's 14-point card corners; submenu segments use its 6-point control
corners. Submenus, project pages, and changing center labels use Relay's
shared entry, exit, and replacement transitions, including Reduce Motion and
increased contrast handling. The active submenu has a detached solid black
backdrop, separated from the wheel by an 8-point gap. It follows the controls'
arc, side edges, and corners with 8-point padding. The backdrop and controls
enter and exit together using Relay's shared replacement transition; Reduce
Motion keeps the fade and removes travel and blur. Hover stays active across
the gap so the controls remain reachable. Project navigation rearms pointer hover so a double-click on
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
The separate submenu backdrop is inspired by
[Libraries.dev's Gooey component at commit bfcb8632](https://github.com/Jakubantalik/Libraries.dev/tree/bfcb86329da15235a5ee2dcdb6417c8a80f82bb1/packages/liquid-gooey),
implemented with native SwiftUI geometry and Relay's existing motion.

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
