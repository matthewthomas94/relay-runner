# Session wheel

A short, stationary **four-finger trackpad tap** toggles the wheel at the pointer.
The menu bar also has **Show Session Wheel**. The wheel remains open after the
fingers lift; selection requires a click. Tap again or click outside to dismiss.
Wheel actions and clicks in its gaps keep it open. Near a display edge, the complete wheel and
its outer controls move inside the usable screen area.

The top three slots show live project sessions, including general, or
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
- Hover Note Taker to reveal **Pause / Resume**, **Start / Save**, and **Cancel**,
  from left to right, on the same liquid submenu used for sessions. Start uses
  the session microphone icon and becomes the app's Save checkmark while recording
  or paused; Save stops, saves and transcribes the recording.
  Pause becomes a play icon for Resume while paused. The plain red X
  cancels the active note, deleting its draft and recording without saving or transcribing. Save uses
  the normal text colour. Cancel is disabled without an active recording, and
  can retry a pending cancellation; capture and save transitions disable the
  other unavailable controls. These controls reuse the
  app's recorder and its existing session restrictions without another capture
  or provider process. The wheel remains open throughout.
- Hover Settings to reveal one continuous curved **Particle intensity** slider
  across the two thirds of its outer arc nearest the sessions, and **Keep Awake**
  in the left third. Click or drag anywhere along the slider: the thumb follows the
  pointer's travel around the wheel and stops at 10% and 100% instead of wrapping.
  Hovering the slider animates in the message-playback particle field at the current
  intensity, even when the overlay is idle, as a preview. It stays up while dragging,
  including when the pointer drifts off the arc, and follows the value live. Leaving
  the slider, releasing a drag elsewhere, or dismissing the wheel animates it away and
  restores the real overlay. The preview only changes the particles: it shows no reply
  pill, plays nothing, pauses no media, and never covers a real recording or playback
  field, which keeps its own theme. It respects Reduce Motion and the Particle field
  setting. The final value is saved to
  `awareness.glow_intensity` (0.1–1.0 in 0.05 steps) when the drag ends, so
  **Settings → Awareness → Intensity** shows the same value, even while Settings is
  open, unless it holds its own unsaved intensity edit. A drag keeps the
  submenu open wherever the pointer goes. The slider is disabled while the particle
  field is off. VoiceOver exposes it as an adjustable control with a percentage.
- **Keep Awake** keeps the Mac awake, including idle periods and with the lid
  closed, until it is switched off or Relay Runner quits. While it is on and the lid
  is closed, the built-in display is dimmed to zero. It is the same control as
  **Settings → General → Startup → Keep Awake**, and it is never saved: every launch
  starts with it off. The first time, macOS asks you to allow Relay Runner's power
  helper once; later toggles and relaunches need no prompt. Its filled lightning bolt
  is white when off and the active tray icon's orange (#FF9502) when on. An hourglass
  means a change is pending, a raised hand means the helper is waiting for your
  approval (click to cancel), and a warning icon explains a failure in its tooltip.
  See [Keep Awake](#keep-awake).
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
  returns to the session wheel and keeps it open. The new session occupies the
  original empty slot, including after paging through projects or waiting for startup.
  Session changes update tiles in place without replaying the whole wheel's transition;
  navigating between menus retains that transition.
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

## Keep Awake

Keep Awake needs two protections to keep media playing with the lid closed:

- Named `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep` IOKit
  assertions, held for as long as it is on. They stop idle system and display sleep.
  Relay holds both before it reports on; if either cannot be created, Keep Awake
  stays off. Holding the display assertion matches Vorssaint's default.
- `pmset -a disablesleep 1`. Closing the lid ignores assertions, so this
  system-wide override is what prevents clamshell sleep.

Before turning it on, Relay reads `pmset -g`. If another app has already disabled
sleep, Relay holds its assertions and never changes or resets that setting. It
reports the external state instead of claiming it changed sleep. While on, Relay
re-reads `pmset -g` every five seconds. An unreadable read is ignored. If sleep has
been re-enabled, whether the override was another app's or Relay's own, Relay shows
the pending state and takes the override back through its helper, without a prompt.
Once taken, Relay owns the override and restores it when switched off. A failed
takeover turns Keep Awake off with an explanation instead of leaving a false on state.

### Power helper and first-time approval

Relay changes the override only through its power helper, `relay-power-helper`, a
launchd daemon packaged in the app at `Contents/Library/LaunchDaemons/` and
registered with `SMAppService`. The first time you turn Keep Awake on, Relay
registers the helper and opens **System Settings → General → Login Items**.
Turn on **Relay Runner** under **Allow in the Background** and authenticate once.
Meanwhile the wheel shows a raised hand and Settings shows **Cancel Keep Awake**. Relay waits up to
two minutes and finishes turning on as soon as you allow it. Otherwise Keep Awake
turns off and says where to allow it. After that, switching Keep Awake on and off and relaunching
Relay Runner reuse the approval with no password prompt. macOS can still remove it.
Turning Relay Runner off in Login Items, a copy signed with a different identity, or
a macOS policy change brings back the approval step, or an explicit "helper
missing" or "not responding" message. Relay never falls back to administrator
scripts, stores a password, or installs a sudoers rule.

Before its first registration, macOS reports the helper as not found, the same
status it gives one absent from the app. Relay registers it only after checking that
the app contains the helper's launchd plist and the executable it names. It calls the
helper missing only when they are absent. When macOS refuses the registration, the
message includes its `SMAppService` error, and the log records the status change.

The helper exposes only four fixed requests: hello, hold the override, release it,
and restore a leftover. None takes a command, path, pid, or power key. It runs only
`/usr/bin/pmset -g` and `/usr/bin/pmset -a disablesleep 0|1`, each with a deadline.
Both sides check code signatures with XPC code-signing requirements, which use the
peer's audit token. The helper accepts only Relay Runner's Developer ID identity
(`com.relayrunner.app`, team `QK9K4AQRNH`) and refuses extra connections. The app
trusts replies only from `com.relayrunner.app.power-helper` with the same team, and
sends a change only on a connection that has already answered. A stuck request times
out and drops its connection. Changes are serialized on one queue.

The override is bound to the app's connection, so it cannot outlast the app. Switching off releases it. Quitting,
crashing, or an update relaunch closes the connection, and the helper restores the
sleep setting it disabled once no Relay connection holds it. The helper records its
ownership in a root-owned file under
`/Library/Application Support/com.relayrunner.app.power-helper/` before changing
anything. launchd also starts it at boot, so it undoes a change left by a helper crash or
power loss. It exits when idle; the registration stays installed across toggles and
relaunches, while the protection itself always ends at quit.

The app writes its own recovery record under
`~/Library/Application Support/relay-runner/` before asking the helper to disable sleep. It clears the record
only after `pmset -g` confirms sleep was restored. Quit closes the connection and
still reads `pmset -g` for up to two seconds before clearing the record. If
restoration cannot be confirmed, or a record survives into the next launch while
sleep is still disabled, Keep Awake shows **Restore sleep**, which asks the helper
to restore it. Relay never re-enables Keep Awake automatically. A lease left by an
earlier build's administrator-approved watchdog is removed at launch, so that
watchdog restores sleep as before.

### Closed-lid dimming

While Keep Awake is actually on, Relay watches the lid through `IOPMrootDomain`'s
`AppleClamshellState` and re-checks it every five seconds. When the lid is closed,
including when Keep Awake turns on with the lid already closed, Relay reads the
built-in display's brightness, records it, and sets only that display to zero. Repeated
close notifications keep the captured value. Opening the lid, turning Keep Awake
off, a failed or lost Keep Awake, quitting, or an update relaunch restores it,
retrying for a few seconds after the lid opens. External displays are never touched.
Lid events during a pending change do nothing until Keep Awake is confirmed on.
An unreadable brightness or lid state leaves the display unchanged. A brightness
left at zero by a crash is restored at the next launch. Dimming
never means sleeping: both assertions and the sleep override stay in place, so
playback continues. Brightness uses DisplayServices, the system framework behind
the brightness keys. If it is unavailable, Keep Awake works without dimming.

The behavior was compared with
[Vorssaint's KeepAwakeManager at commit 5d1ffa07](https://github.com/vorssaint/vorssaint-utils/blob/5d1ffa07c83665c83123fdf734a70843cd1f8771/Sources/Vorssaint/Services/KeepAwakeManager.swift)
and its display services (ownership recorded before mutation, serialized enable and
restore, restoration at quit, independent system and display assertions, and
lid-gated dimming of only the built-in panel with a recorded restore). Relay replaces Vorssaint's
sudoers setup with an approved, connection-bound helper; no source is vendored.
Vorssaint also requests sleep after restoring while the lid is already closed; that
cleanup step is not part of this control.

The icon transitions use `RelayMotion`'s change duration (about 225 ms). Off and on
share the filled bolt, so only its colour eases. Other changes contract and fade the
old symbol, then expand the new one, without overlap, and retarget if the state
changes mid-swap. Nothing loops while a state rests. Reduce Motion keeps the fades
and colour change without scale or blur.

## Input and lifecycle

**Settings → General → Session wheel → Wheel haptics** is on by default. On a
Force Touch trackpad, moving into an enabled cell, center, or submenu control gives
a firm generic pulse; accepted actions give the same generic confirmation. Hover ticks have an
80 ms cooldown and do not repeat while staying on a control. Gaps, disabled
controls, background refreshes, and opening under a stationary pointer stay silent.
Feedback uses the current macOS haptic performer and respects system preferences;
macOS may suppress it when fingers are off the trackpad. The four-finger gesture's
timing is unchanged, and there is no delayed opening pulse.

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
env -u SDKROOT swift test --filter 'FourFingerTapGestureTests|SessionWheelTests|SessionWheelHapticsTests|SessionWheelMotionTests|MeetingNoteCoordinatorTests|ProgramBoardOverlayControllerTests|VoiceReplyBadgeTests|STT|VoiceBridgeFocusTests|CapsLockGestureTests'
```

Run `KeepAwakeControllerTests|KeepAwakePowerHelperTests|ConfigManagerTests|GeneralConfigTests`
for Keep Awake and intensity persistence, and `OverlayPresentationMotionTests` for the
slider's particle preview. Keep Awake tests use an in-memory pmset, helper
registration, lid, and display. The helper tests run its real XPC service on an
in-process anonymous listener. They cover peer rejection, connection limits, leases
released on disconnect, bounded replies, and approval reuse, denial and revocation.
No test registers the helper, shows a prompt, runs as root, or changes this Mac's
power settings or brightness. `python3 -m unittest discover -s tests -p
'test_app_signing.py'` checks the packaged helper's launchd metadata and signing
checks. `scripts/build-dmg.sh` runs `app_signing.py check-helper` on every build,
and verifies the helper's Developer ID requirement on signed builds.

Set `RELAY_WHEEL_RENDER_DIR` to an output directory to export SwiftUI previews
from `SessionWheelTests.testWheelRendering`, including the `settings-*` states. The motion tests also export each
submenu's liquid keyframes and a GIF sampled from the native hover/reversal spring.
Tests use fake capture and temporary
spools; they do not open the microphone or send commands to live sessions.

Installed-app checks still require a physical trackpad and live sessions: open
and dismiss across displays, reject swipes and pinches, navigate to every outer
control, start a project from a later page, replay a background session's reply,
record and send to each provider, stop one session while the others continue, and
repeat after sleep or reconnecting a trackpad. Drag the intensity slider past
both ends while watching the particle field, then reopen Settings.
Keep Awake requires its own manual checks on the installed app. Automated tests and
rendered fixtures cover the controller, helper, and dimmer with fakes. They do not
establish the macOS approval, privileged, closed-lid, brightness, or audible outcomes.
These physical checks are pending the user's verification, including RR-436's closed-lid
playback retest:

1. Quit Vorssaint, or turn its Keep Awake off, and confirm `pmset -g` shows
   `SleepDisabled 0`.
2. Approve once: turn on Keep Awake from the wheel. System Settings opens at Login
   Items; allow **Relay Runner** in the background. The raised hand becomes an orange
   bolt without another prompt.
3. Confirm `pmset -g` shows `SleepDisabled 1`, and
   `pmset -g assertions | grep "Keep Awake is on in Relay Runner"` lists both
   `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`.
4. Cycle the toggle off and on twice. No password or approval prompt appears, and
   `SleepDisabled` follows each change.
5. Quit and relaunch Relay Runner, then repeat step 4. There is still no prompt.
6. With Keep Awake on, play a video and close the lid for at least 30 seconds. The
   built-in display stays dark (brightness zero) and playback continues. Reopen the
   lid: the previous brightness returns and playback has continued throughout.
7. Turn Keep Awake off: both assertions disappear and `SleepDisabled` returns to `0`.
   Turn it on again and quit Relay Runner; the result must be the same, and the
   brightness must be unchanged.

Also force-quit while it is on; `SleepDisabled` must return to `0`. Turn Relay
Runner off in Login Items and activate Keep Awake. It must ask for approval again
rather than report on.
