# RR-448 gate: hook and speech stages against the last all-Python release (RR-482)

Date: 2026-11-14. Hardware: MacBook Pro (Mac16,1), Apple M4, 24 GiB, macOS 27.0.1, the same Mac as [RR-479](RR-448-rust-speech-prototype.md).

## Decision

The decision was made before this report. The user chose on 2026-11-13 to continue the port: the voice bridge in RR-489 to RR-493 and the daemon in RR-494 to RR-500. This report records the gate measurements RR-448 asked for. It makes no continue-or-stop recommendation and does not cost the bundled-interpreter alternative.

## Builds compared

| Name | Build | What runs in Python |
| --- | --- | --- |
| **Python** | Release **v0.5.4** (`4b61caaa`, published 2026-11-11), the `RelayRunner.dmg` from the `relay-runner-updates` release, sha256 `477e1197…4d04`. It is the last release with no Rust: `git ls-tree -r v0.5.4` has no `.rs` file. | Everything: hook, reply helper, speech in the bridge process, bridge, daemon |
| **Rust** | `main` at **`b0b7857f`** (RR-481 merged), built in this worktree with `RELAY_SKIP_APPLICATIONS_REFRESH=1 ./scripts/build-dmg.sh`. Signed with the Developer ID, not notarised. Version string 0.5.4 (109). | Bridge, messenger and daemon. The hook and reply helper are `relay-rs`, speech is `relay-speech`. |

No release contains either Rust stage yet: RR-478 merged on 2026-11-13 and RR-481 on 2026-11-14, after v0.5.4. The live measurements below use the app installed on this Mac, which was built from `main` on 2026-11-14 at 09:38 and runs `relay-rs` and `relay-speech` (`ps` shows `Contents/MacOS/relay-speech` as the bridge's child). No rollback variable is set: `launchctl getenv` returns nothing for `RELAY_HOOK_RUNTIME`, `RELAY_SPEECH_RUNTIME` and `RELAY_BRIDGE_RUNTIME`.

Python figures for speech come from the speech engine v0.5.4 ships. `services/tts_worker.py` is still bundled as the fallback and `preview_voice.py` is byte-identical to v0.5.4's. They ran in the venv this Mac built for the Python releases: Python 3.13.13, onnxruntime 1.28.0, kokoro-onnx 0.5.0.

## Summary

| Measure | v0.5.4 (Python) | `b0b7857f` (Rust hook and speech) |
| --- | --- | --- |
| `RelayRunner.dmg` | 22.7 MB (22,716,363 bytes) | 46.8 MB (46,785,105 bytes) |
| Sparkle `RelayRunner.zip` | 21.2 MB | 43.3 MB |
| App bundle on disk | 51.6 MiB | 108.0 MiB |
| Services venv, fresh install | 231.8 MiB, 41 packages | 13.3 MiB, pip only |
| Speech model in `~/.local/share/kokoro` | 337.4 MiB | 337.4 MiB |
| **Installed total, fresh install** | **620.8 MiB** | **458.7 MiB** |
| First-run Python setup | 67.8 s, 41 archives, 57.1 MB downloaded | 14.5 s, nothing downloaded |
| Speech model download | Same two files, 353.7 MB | 19.6 s here, 353.7 MB |
| Hook latency, median of all events | 238 to 280 ms | 36 to 43 ms |
| Synthesis to first WAV in live sessions, median | 1,058 ms (171 utterances) | 607 ms (8 utterances) |
| Speech service idle after load, footprint | 413 MiB | 421 MiB |
| Speech service idle CPU | 0.11% of a core | 0.04% of a core |
| Defects after release | None possible: no release contains the Rust stages | |
| Shipped Python | 66 modules, 61,376 lines; numpy, onnxruntime, kokoro-onnx, huggingface_hub and their dependencies | 69 modules, 63,328 lines; standard library only by default |

## 1. Download and installed size

```bash
gh release download v0.5.4 -R matthewthomas94/relay-runner-updates -p RelayRunner.dmg
stat -f%z RelayRunner.dmg dist/RelayRunner.dmg dist/RelayRunner.zip
hdiutil attach -readonly -nobrowse -mountpoint /tmp/rr482/mnt054 RelayRunner.dmg
du -sk "/tmp/rr482/mnt054/Relay Runner.app" "dist/Relay Runner.app"
du -sk "dist/Relay Runner.app/Contents/"*
```

The download doubles, from 22.7 MB to 46.8 MB, and the bundle from 51.6 MiB to 108.0 MiB. Most of the growth is two executables in `Contents/MacOS`: `relay-speech` at 51.2 MB, with ONNX Runtime linked statically, and `relay-rs` at 7.2 MB. Notarisation only staples a ticket, so the released DMG will be within a few kilobytes of the figure here.

Application Support holds the services venv. The figures are for a fresh install; [First-run setup](#2-first-run-setup) shows how they were measured. The model in `~/.local/share/kokoro` is the same for both builds: `kokoro-v1.0.onnx` (325,532,387 bytes) and `voices-v1.0.bin` (28,214,398 bytes).

| Part | v0.5.4 | `b0b7857f` |
| --- | --- | --- |
| App bundle | 51.6 MiB | 108.0 MiB |
| `relay-runner/services/.venv` | 231.8 MiB | 13.3 MiB |
| `~/.local/share/kokoro` | 337.4 MiB | 337.4 MiB |
| **Total** | **620.8 MiB** | **458.7 MiB** |

Both totals leave out the Python interpreter. This Mac has Homebrew's Python 3.13; a Mac with no Python from 3.10 to 3.13 also gets a relocatable Python, which `relay-bridge` describes as about 18 MB. Both builds still need it. User data is left out too: notes, tickets, diagnostics and orchestrator worktrees.

**An upgrade does not shrink the venv.** `relay-bridge` only checks that `requirements.txt` imports. It never removes packages from an existing venv, so a Mac upgraded from v0.5.4 keeps the speech packages it no longer uses. This Mac's venv is 217 MB. They do keep `RELAY_SPEECH_RUNTIME=python` working without a download for the fallback release.

## 2. First-run setup

Each requirements file was installed into a new venv with the interpreter `relay-bridge` picks on this Mac. `--no-cache-dir` was used so that every package is downloaded. The model was downloaded from the URL that `relay-bridge` uses since RR-481.

```bash
PY=/opt/homebrew/opt/python@3.13/bin/python3.13
$PY -m venv venv-$v
venv-$v/bin/python3 -m pip install --quiet --no-cache-dir --upgrade pip
venv-$v/bin/pip install --no-cache-dir -r req-$v.txt   # v0.5.4's requirements.txt, then b0b7857f's
curl -fsSL -o models/$f -w "%{size_download} %{time_total}\n" \
    https://huggingface.co/fastrtc/kokoro-onnx/resolve/main/$f
```

| Step | v0.5.4 | `b0b7857f` |
| --- | --- | --- |
| Create venv | 4.9 s | 8.2 s |
| Upgrade pip | 4.0 s | 4.7 s |
| Install requirements | 58.9 s: 41 archives, 57.1 MB | 1.7 s: nothing to install (`tomli` is only for Python < 3.11) |
| **Python setup** | **67.8 s** | **14.5 s** |
| Model, 2 files, 353.7 MB | Same files, through `huggingface_hub.hf_hub_download` | 16.5 s + 3.1 s with `curl` |

What v0.5.4 downloads: numpy, onnxruntime, kokoro-onnx, huggingface_hub and their dependencies, including espeakng-loader and phonemizer-fork (GPL), babel, rdflib, csvw and hf-xet. Today these resolve to onnxruntime 1.32.0, not the 1.28.0 on this Mac, so a fresh v0.5.4 install runs a different ONNX Runtime from the one measured below. `b0b7857f` downloads only pip and the model, plus the interpreter if the Mac needs one. The venv creation times differ by network and disk noise; both builds do the same work in that step.

The model download was timed once, with `curl`, on this network. v0.5.4 fetches the same two files from the same Hugging Face repository through `huggingface_hub`, which was not timed separately.

## 3. Memory and idle CPU, 10 minutes, session active, no speech

Two 10-minute runs took a sample every 10 seconds: `ps -o rss=,time=` for resident memory and CPU time, and `top -l 1 -stats pid,mem` for the physical footprint. `/tmp/relay_speech_events.jsonl` has no event in either window, so nothing was spoken.

**Resident memory is not a usable measure here.** During the first run a release build was compiling on the same Mac. macOS compressed the idle model pages, and the resident size of the live `relay-speech` fell to 45 MiB while its footprint stayed at 677 MiB. The tables report footprint, which counts compressed memory. Resident size is listed only for the record.

### Live session on the Rust build

Run 2, 10:39 to 10:49, after the build had finished. The session had been running for 34 minutes.

| Process | Footprint | Resident | CPU over 593 s |
| --- | --- | --- | --- |
| Bridge, `voice_bridge.py` (Python in both builds) | 43 MiB | 29 to 32 MiB | 44.7 s, **7.5% of a core** |
| `relay-speech` | 677 MiB | 45 MiB | 0.5 s, 0.08% |
| Daemon, `orchestrator.py` (Python in both builds) | 82 MiB | 35 to 42 MiB | 7.2 s, 1.2% |

Run 1, 10:08 to 10:18, during the build: bridge 8.3% of a core and daemon 5.0%, with this worker run being dispatched; `relay-speech` 0.09%.

### The two speech engines side by side

v0.5.4 runs speech inside the bridge, and the Python release cannot run beside the live session. So both speech services ran at the same time, each in its own temporary `HOME` with private sockets, state file and event log. Each loaded the model, answered `hello`, and was left idle for 10 minutes. Because the `HOME` was private, neither could take the live session's audio lock. The harness is described under [Reproducing](#reproducing).

| Service | Ready after start | Footprint | CPU over 593 s |
| --- | --- | --- | --- |
| Python, `speech_service.py` with the v0.5.4 engine | 3.0 s | 413 MiB | 0.7 s, 0.11% |
| Rust, `relay-speech` | 2.3 s | 421 MiB | 0.2 s, 0.04% |

The peak for one sentence is from `/usr/bin/time -l` over three runs of each preview. The figures are the maximum resident size, then the peak footprint.

| Engine | Maximum resident | Peak footprint |
| --- | --- | --- |
| Python, `preview_voice.py` | 607 to 626 MiB | 539 to 598 MiB |
| Rust, `relay-speech preview` | 587 MiB | 560 MiB |

**Reading.** At idle the two engines use the same memory and almost no CPU; the model is most of the memory in both. The live `relay-speech` holds 677 MiB, about 256 MiB more than at load. That is what ONNX Runtime keeps after synthesising: the session had already spoken. v0.5.4 has the same cost inside its bridge, which RR-448 measured at 506 MB resident on 0.5.3. Splitting speech out added one process of its own to the memory total, about 40 MiB, the size of the Python bridge without speech. Over the two stages, memory did not change in any meaningful way.

**The bridge's idle CPU stayed at 7.5 to 8.3% of a core.** The two Rust stages do not touch it, so the bridge port is the place to look. [Risks](#7-risks-for-the-bridge-and-daemon-stages) has more.

## 4. Hook latency and time to first audio

### Hook

The black-box timing case from RR-477, run three times for each implementation on the quiet Mac (load average 7 falling to 4):

```bash
cd tests/contract
RELAY_HOOK_CMD="/usr/bin/python3 '<v0.5.4 mount>/Contents/SharedSupport/services/relay_completion_hook.py'" \
RELAY_REPLY_CMD="/usr/bin/python3 '<v0.5.4 mount>/Contents/SharedSupport/services/relay_reply.py'" \
    /usr/bin/python3 -m unittest test_hook_contract_timing
RELAY_HOOK_CMD="'$RS' hook" RELAY_REPLY_CMD="'$RS' reply" /usr/bin/python3 -m unittest test_hook_contract_timing   # RS=dist/…/relay-rs
```

Each run makes 20 or 21 invocations covering SessionStart (Claude), UserPromptSubmit, Stop, PreCompact and PostCompact. The case uses a 3 MiB transcript, which is the slowest honest input.

| Provider | v0.5.4 median (slowest) | Rust median (slowest) |
| --- | --- | --- |
| Claude | 247, 238, 245 ms (293 to 322 ms) | 38, 43, 39 ms (55 to 65 ms) |
| Codex | 280, 264, 241 ms (305 to 411 ms) | 43, 41, 36 ms (49 to 66 ms) |

The Rust hook is about six times faster, and its slowest call is about a sixth of v0.5.4's. Both are well inside the providers' 2-second limit. Most of the Python time is the interpreter: `/usr/bin/python3` (3.9.6) takes a median of 115 ms to run `-c pass`, against 10 ms for `relay-rs --version`, over 20 runs each. The first set, run while the build was compiling, gave Python medians of 251 to 698 ms with a slowest of 1,167 ms, and Rust 34 to 49 ms with a slowest of 179 ms. Under load the Python hook comes closer to the limit, and the Rust hook barely moves.

### Time to first audio

From the live speech event log, the time from `tts_enqueued` to `first_wav_ready` for each utterance. That is synthesis of the first chunk, before playback is scheduled.

```bash
python3 firstaudio.py   # reads /tmp/relay_speech_events.jsonl, groups events by utterance_id
```

| Period | Speech engine | Utterances | Median | 10th to 90th percentile |
| --- | --- | --- | --- | --- |
| 2026-11-11 13:29 (v0.5.4 tagged) to 2026-11-14 00:17 (RR-481 merged) | Python | 171 | 1,058 ms | 710 to 1,908 ms |
| From 2026-11-14 09:38 (Rust build installed) | Rust | 8 | 607 ms | 435 to 921 ms |

Events between 00:17 and 09:38 were left out, because the speech engine for that window is not known. Over all the Python history in the log, from 2026-10-30, the figure is 1,038 ms over 497 utterances. Eight Rust utterances are too few for a firm figure, and the sentences in the two periods differ. Even so, the gap agrees with RR-479's warm measurement on fixed text: 889 ms for Python against 643 ms for Rust.

A cold start, from a new process to a WAV on disk, for the RR-479 sentence "Sure, I can take a look at that for you." in `am_puck`, five alternating runs each. The live session and other worker runs were using the Mac during these runs:

```bash
"$VENV/bin/python3" services/preview_voice.py --voice am_puck --text "$T" --output out.wav
"/Applications/Relay Runner.app/Contents/MacOS/relay-speech" preview --voice am_puck --text "$T" --output out.wav
```

| Engine | Median | Range |
| --- | --- | --- |
| Python | 5.61 s | 4.89 to 6.07 s |
| Rust | 4.31 s | 4.03 to 4.39 s |

These are about four times RR-479's cold figures, which were 1.49 s and 1.02 s at priority 20 on a quieter Mac. Read them for the gap between the engines, not as absolute values. Rust was faster in every pair, and its spread was smaller.

## 5. Defects after release, and use of the rollback switches

**No release contains either Rust stage, so there are no post-release defects yet.** v0.5.4 was published on 2026-11-11. RR-478 (hook) merged on 2026-11-13 and RR-481 (speech) on 2026-11-14. Neither has been through Sparkle, and the only install is this Mac's local build, running since 2026-11-14 09:38.

What was checked:

- **Tickets.** The board's tickets after RR-478 are RR-479 to RR-500: the planned port stages, RR-488 (a feature) and this report. None reports a defect in `relay-rs hook`, `relay-rs reply` or `relay-speech`.
- **Commits.** `git log dc2022b2..b0b7857f` (from the RR-478 merge) for the hook, reply and speech sources and `ProcessManager.swift` has no fix after either stage merged. The two `fix:` commits in that range are RR-480, to the Python speech process before the Rust service, and RR-492, to the Rust bridge.
- **Support diagnostics.** This Mac's `support-diagnostics/v1` has 119 files written since 2026-11-12. Its 90 `failed` events are all `provider_readiness` (45 with an exit code, 9 `process_start_failed`) and `workspace_readiness` (36). None comes from the hook or speech. The diagnostics have no phase for the hook or the speech service at all: the phases recorded are provider readiness, workspace readiness, setup, bridge readiness, app launch, orchestrator launch, bridge recovery and MetricKit delivery. A hook or speech failure would not appear there.
- **Rollback switches.** `RELAY_HOOK_RUNTIME` and `RELAY_SPEECH_RUNTIME` are unset on this Mac. Nothing records their use anywhere else, so for other users the count can only come from user reports after a release.

## 6. Remaining Python

The modules `build-dmg.sh` copies into `Contents/SharedSupport/services`:

```bash
ls "<app>/Contents/SharedSupport/services/"*.py | wc -l; cat "<app>/Contents/SharedSupport/services/"*.py | wc -l
```

| | v0.5.4 | `b0b7857f` |
| --- | --- | --- |
| Shipped modules | 66 | 69 |
| Lines | 61,376 | 63,328 |
| All of `services/*.py` in the source tree | n/a | 71 modules, 64,913 lines |
| Third-party packages installed | numpy, onnxruntime, kokoro-onnx, huggingface_hub, plus 37 transitive | None. `tomli` only on Python < 3.11 |

The Python grew, because no Python was removed: each stage keeps its implementation as the one-release fallback. These modules have a Rust replacement and can go once the fallbacks are removed:

| Fallback | Modules | Lines |
| --- | --- | --- |
| Hook and reply helper (`RELAY_HOOK_RUNTIME=python`) | `relay_completion_hook.py`, `relay_reply.py` | 1,880 |
| Speech (`RELAY_SPEECH_RUNTIME=python`) | `tts_worker.py`, `speech_coordinator.py`, `speech_player.py`, `speech_service.py`, `preview_voice.py` | 4,342 |

`voice_bridge.py` still imports `speech_coordinator` and `tts_worker` at module level for its in-bridge speech mode, `RELAY_SPEECH_SERVICE_MODE=legacy`. So the speech modules cannot be deleted before the bridge, or that mode, goes.

Third-party imports were found by parsing every module's `import` statements against `sys.stdlib_module_names`. numpy, kokoro_onnx and huggingface_hub are imported only by `tts_worker.py` and `preview_voice.py`, which load only under the speech fallback, and by `continuity_fault_harness.py`, which is not shipped. `tomli` is imported by `config.py` and `toml_compat.py` only on Python < 3.11. By default the shipped Python is standard library only, as expected. It still needs an interpreter and a venv.

## 7. Risks for the bridge and daemon stages

1. **The size budget is nearly spent.** The two stages doubled the download, to 46.8 MB, and `relay-speech` alone is 51 MB because ONNX Runtime is linked into it. The bridge and daemon add more Rust executables. If each one links its own copy of the shared crates (SQLite, TLS, JSON), the bundle will keep growing. A single multi-call `relay-rs`, which already carries the hook, the reply helper and the bridge, holds this down. Linking ONNX Runtime into a second executable would not.
2. **Installed size falls only with a fresh install.** An upgrade keeps the full speech venv (217 MB on this Mac), because `relay-bridge` never removes packages. The final stage, RR-487, needs to delete or rebuild the venv. Otherwise upgraded users never see the saving.
3. **The bridge's idle CPU is real and untouched.** The Python bridge used 7.5 to 8.3% of a core in two idle 10-minute windows. The speech service uses 0.04 to 0.08%, so this cost is the bridge's own loop. A port that keeps its polling structure will keep the cost: RR-448 already found that CPU cost in this codebase comes from architecture, not the interpreter. The bridge stage should measure idle CPU against this baseline and should not port a polling loop as is.
4. **Memory will not drop much.** The model is most of the speech service's 413 to 677 MiB, and the bridge (43 MiB) and daemon (82 MiB) are small. Porting them can save tens of megabytes, not hundreds. Nobody should expect a memory win from stages 3 and 4.
5. **Field evidence is missing.** No release contains either Rust stage, and diagnostics have no hook or speech phase. So the defect rate the gate was meant to measure is zero by construction, and the bridge stage starts before the hook and speech stages have been in users' hands. The bridge cut-over (RR-493) will ship with three Rust stages untried in the field. Adding diagnostics for hook and speech failures, and for which runtime each switch selected, would let a release show rollback use and defect rate. Without them, both depend on user reports.
6. **Three fallbacks at once.** After RR-493 a user can be on any of eight combinations of `RELAY_HOOK_RUNTIME`, `RELAY_SPEECH_RUNTIME` and `RELAY_BRIDGE_RUNTIME`, and the daemon will add a fourth switch. The Python speech fallback also needs the speech packages that a fresh install no longer has. Removing each fallback after its single release, as planned, keeps the combinations testable.
7. **The Python hook's margin shrinks under load.** The Python hook's slowest call reached 1,167 ms of the providers' 2-second limit while a build was compiling. The Rust hook stayed under 180 ms. This is a reason to keep the Rust hook as the default and the Python fallback short-lived. It does not affect the bridge or daemon directly.

## Reproducing

Temporary files lived under `/tmp/rr482` and are not committed.

- **Isolated speech services.** A small Python harness takes a name, a duration and a service command. It makes a fresh `HOME` whose `.local/share/kokoro` links to the downloaded model, and copies `config.toml` (voice `am_puck`). It sets `VOICE_COMMAND_STATE_FILE`, `SPEECH_EVENT_LOG`, `TTS_CONTROL_SOCK`, `VOICE_STATE_SOCK` and `VOICE_MODELS_DIR` to paths inside that folder. It starts the service with `--socket <tmp>/s.sock --config <tmp>/config.toml`, sends `{"id":1,"op":"hello","protocol":1}`, records the time to the answer, sleeps, then sends `shutdown`. The Python service was started from `services/` as `<venv>/bin/python3 speech_service.py`, and the Rust one as `Contents/MacOS/relay-speech`.
- **Sampler.** Every 10 seconds, for each process id: `ps -o rss=,time= -p <pid>` and `top -l 1 -pid <pid> -stats pid,mem`. CPU share is the CPU time used across the window divided by the window's length.
- **First audio from the log.** Group `/tmp/relay_speech_events.jsonl` by `utterance_id`, take the first `tts_enqueued` and `first_wav_ready` `at` of each, and split by the period boundaries in section 4.
