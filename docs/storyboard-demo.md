# Localhost storyboard demo

This is a scripted recording aid for the six-frame demo. It stages a blank page
and reveals a supplied asset; the rendering fix and spoken responses are rehearsed.
The overlays are native Relay Runner, and the viewing beat performs a real Relay
Vision screenshot. No agent provider, ticket, or worker is involved.

Build the signed local app without replacing the installed app or release archives:

```sh
env -u SDKROOT ./scripts/build-dmg.sh --app-only
```

Stop any active voice session and quit Relay Runner before launching this copy.
The installed and demo copies share runtime sockets and must run one at a time:

```sh
open -n 'dist/Relay Runner.app' --args --storyboard-demo
```

Use Relay's existing Python runtime to prepare the three spoken lines:

```sh
DEMO_PYTHON="$HOME/Library/Application Support/relay-runner/services/.venv/bin/python3"
"$DEMO_PYTHON" scripts/relay-storyboard-demo prepare
"$DEMO_PYTHON" scripts/relay-storyboard-demo serve --asset /absolute/path/to/asset
```

The asset can be an HTML folder with `index.html`, an HTML file, an image, or a
video. The server binds only to `127.0.0.1:3000`. Without `--asset`, it serves the
blank page for preparation and refuses playback. Keep this server running.

For the two supplied clips, play Clip1 once and then loop Clip2:

```sh
"$DEMO_PYTHON" scripts/relay-storyboard-demo serve \
  --asset '/Users/matthewthomas/Movies/Skeletal Ambi/DemoClip1.mp4' \
  --loop-asset '/Users/matthewthomas/Movies/Skeletal Ambi/DemoClip2.mp4'
```

Clip2 preloads during Clip1. The single final validation says “You should see the
video rendering now” about two seconds after the investigation message ends,
while Clip1 begins playing. Clip1 still plays in full before Clip2 loops.
Resetting the page or starting another take restarts the pair from Clip1.

Start the screen recording from the desktop, then run in another terminal:

```sh
"$DEMO_PYTHON" scripts/relay-storyboard-demo run --lead-in 5
```

The take (about 55 seconds with the supplied clips) types
the opening transcript into the listening overlay, plays the server confirmation,
opens Chrome, captures the screen with
Relay Vision, plays the investigation line, reveals the asset, and plays the final
line. Audio is pre-rendered in the configured standard voice; macOS recording must
capture system audio if the finished video needs speech. Double-tap Control or
Ctrl-C cancels playback. Running again resets the page for another take.

After filming, quit the demo copy and reopen `/Applications/Relay Runner.app`.
Normal launches ignore scripted recording events.
