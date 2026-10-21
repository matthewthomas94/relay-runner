# Session wheel

A short, stationary **four-finger trackpad tap** toggles the wheel at the pointer.
The menu bar also has **Show Session Wheel**. The wheel remains open after the
fingers lift; selection requires a click. Tap again or click outside to dismiss.
Wheel actions and clicks in its gaps keep it open. Near a display edge, the complete wheel and
its outer controls move inside the usable screen area.

The top three slots show live project sessions, including general-tasks, or
**Start session** when empty. The bottom three are **Workspace**, **Note Taker**,
and **Settings**, from left to right. Sessions keep their positions as other
sessions start or stop. Relay's existing four-session limit still applies:
when a fourth session is running, **More sessions** opens a nested wheel with all
sessions. An overflow session fills a top slot when one becomes free.

- Click the session wheel's center to toggle the Workspace while keeping the wheel
  open. Its glyph uses the notch's live status, colours and motion: an upright
  four-dot square at rest, rotating while working, orange while listening and
  purple for response/playback states. Opening Workspace merges the dots into
  one bead, then stretches it into a thin X; closing reverses the liquid morph.
  Another click can reverse the morph immediately.
  Nested wheels show a left arrow in the center. It morphs through the same bead
  when switching to or from the dots or X. Escape backs out of project wheels
  without closing the session wheel or toggling Workspace.
- Click Workspace, Note Taker, or Settings to open that Workspace tab, including
  when the Workspace is already open. The wheel stays open and above Workspace,
  even when a tab takes keyboard focus.
- Hover Note Taker to reveal **Pause / Resume**, **Start / Stop**, and **Cancel**,
  from left to right, on the same liquid submenu used for sessions. Start becomes
  Stop while recording or paused; Stop saves and transcribes the recording.
  Pause becomes a continuation arrow for Resume while paused. The plain red X
  cancels the active note, deleting its draft and recording without saving or transcribing. Stop uses
  the normal text colour. Cancel is disabled without an active recording, and
  can retry a pending cancellation; capture and save transitions disable the
  other unavailable controls. These controls reuse the
  app's recorder and its existing session restrictions without another capture
  or provider process. The wheel remains open throughout.
- Hover a session to reveal three controls on the arc just outside its slot:
  an icon-only **Play / Stop playback / Replay message**, **Record / Stop recording
  and send message**, and **Stop session**. Tooltips and VoiceOver retain these labels.
  Play and replay share the triangle; the square stops playback. The microphone
  becomes a live, speech-reactive waveform while recording; the power icon ends the session.
- Stop playback cancels the selected session's audio and dismisses its playback
  pill and particle overlay. The wheel stays open, and queued replies remain
  available to play later. All submenu actions keep the wheel open. Click the
  active waveform to send the message to that session; its controls stay available
  afterward. Ending a session frees its slot without closing the wheel.
- Click an unselected session to switch voice to it without
  opening Workspace; the notch briefly reports the switch. Click the currently
  selected session to open Workspace directly to its terminal. Both keep the wheel open.
- Click an empty slot to enter the project wheel. Click an available registered
  project to start its session without opening the Workspace. The center shows
  an icon-only left arrow, with **Back** retained in tooltips and VoiceOver labels.
  The center has no subtitle; notices and availability details stay in its tooltip
  and accessibility hint.
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
and subtle borders, with Bai Jamjuree typography, purple session dots, and a red
end-session control. Playback and recording icons use the primary text color. The wheel has
no outer border. Segments use consistent 8-point spacing between their straight
edges, around the center and outer perimeter. The 34-point-deep outer
controls follow the wheel's tangent, keeping their icons upright on
the lower half, with each icon centered inside its segment. Main
wedges use Relay's 14-point card corners; submenu segments use its 6-point control
corners. Project pages and changing center content retain their existing wheel
transitions, including Reduce Motion and increased contrast handling.
The active submenu has a detached solid black
backdrop, separated from the wheel by an 8-point gap. It follows the controls'
arc, side edges, and corners with 8-point padding. On hover, this backdrop grows
out of the main disc as a joined liquid surface, then separates into its detached
resting shape. Leaving reverses the morph. The disc and emerging submenu share a
blur-and-alpha-threshold silhouette beneath the unfiltered controls. One native
spring drives the surface and controls together, reverses from its current position
and velocity, and lets an outgoing slot merge back while another opens. Controls
emerge from behind the disc and become clickable as they settle outside it;
playback or recording icon changes do not restart the submenu entrance.
Reduce Motion fades the submenu in its final position without merging, travel,
or blur. Hover stays active across
the gap so the controls remain reachable. Project navigation rearms pointer hover so a double-click on
an empty slot cannot launch a project in the same position.

The recording waveform reads a bounded 100 ms RMS window from the existing audio
buffer only for the session that owns the recording. It never consumes samples
or opens another microphone capture. Reduce Motion holds both the waveform and
four-dot glyph at rest and crossfades between the glyph, X and Back arrow instead of morphing.

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
The submenu morph follows the shared-silhouette technique in
[Libraries.dev's Gooey component at commit d243bdd3](https://github.com/Jakubantalik/Libraries.dev/tree/d243bdd327a1215753e6b605e1e1957d7e0dcc59/packages/liquid-gooey),
implemented with SwiftUI Canvas filters and native interruptible springs. The React
package is not embedded; the interactive controls retain Relay's own styling.

## Verification

Run the focused checks with:

```sh
env -u SDKROOT swift test --filter 'FourFingerTapGestureTests|SessionWheelTests|SessionWheelMotionTests|MeetingNoteCoordinatorTests|ProgramBoardOverlayControllerTests|VoiceReplyBadgeTests|STT|VoiceBridgeFocusTests|CapsLockGestureTests'
```

Set `RELAY_WHEEL_RENDER_DIR` to an output directory to export SwiftUI previews
from `SessionWheelTests.testWheelRendering`. The motion tests also export each
submenu's liquid keyframes and a GIF sampled from the native hover/reversal spring.
Tests use fake capture and temporary
spools; they do not open the microphone or send commands to live sessions.

Installed-app checks still require a physical trackpad and live sessions: open
and dismiss across displays, reject swipes and pinches, navigate to every outer
control, start a project from a later page, replay a background session's reply,
record and send to each provider, stop one session while the others continue, and
repeat after sleep or reconnecting a trackpad. Automated tests and rendered
fixtures do not establish those hardware and audible outcomes.
