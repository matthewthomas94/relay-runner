# RR-448 follow-up: Kokoro speech in Rust, prototype and measurements (RR-479)

Date: 2026-11-12. Hardware: Apple M4 (4 performance and 6 efficiency cores), 24 GiB, macOS 27.0.1, on battery. Branch: `relay/rr-479`.

## Result

TBD-RESULT

## What was built

`rust/relay-speech-proto/` is a prototype, not production code. It is a Cargo workspace of its own, excluded from the workspace in `rust/`, so the app build, CI and `scripts/rust-licenses` do not see it.

- `src/` (about 500 lines) does what kokoro-onnx 0.5.0 does around the model: filter phonemes to the model's 114-symbol table, split into batches under 510 symbols, pick the voice's style vector for the batch length, run the model, trim silence, write 24 kHz mono 16-bit WAV. It reads the same `kokoro-v1.0.onnx` and `voices-v1.0.bin` from `~/.local/share/kokoro`. Like `services/tts_worker.py`, it sets no session options and uses speed 1.0.
- Phonemes come from one of two non-GPL crates, chosen with `--g2p`: `misaki-rs` built without its `espeak` feature, or `loqui-g2p`. The second was added because the first is not usable on its own (see [Phoneme differences](#phoneme-differences)).
- `corpus.tsv` holds 57 sentences in ten categories: ordinary replies, code identifiers, file paths, numbers, dates, version strings, ticket ids, product names, unknown words, and symbols such as URLs and acronyms.
- `compare.py` renders the corpus with both stacks for all four voices, measures them and writes the listening page.
- `deny.toml` is the licence gate for this crate.

### Versions and upstream commits

Every crate is pinned: the four direct dependencies with `=` requirements in `Cargo.toml`, and all 117 packages by the committed `Cargo.lock`, which every build uses with `--locked`. The commit is the one recorded inside each published crate (`.cargo_vcs_info.json`).

| Crate | Version | Upstream commit | Licence |
| --- | --- | --- | --- |
| `ort`, `ort-sys` | 2.0.0-rc.15 | `pykeio/ort@5c564c58507f35fa4adc387a79fce1016e73956b` | MIT OR Apache-2.0 |
| `loqui-g2p` | 0.4.0 | `Awakened-Labs/loqui@717691aadf67408c85d87dc33e5d1d77b2ea4b4d` (`crates/loqui-g2p`) | MIT; embedded data Apache-2.0 and MIT |
| `misaki-rs` | 0.8.0 | `MicheleYin/misaki-rs@5a6ca6ccc5a234f583cbcac2e1c25b16c33405e5` | MIT |
| `zip` | 2.4.2 | `zip-rs/zip2@2283915c1e03477ce7cf9e6a0cfb92408c6108ec` | MIT |

RR-448 cited a different commit for `ort` 2.0.0-rc.15; the one above is what the crate on crates.io records.

The Python stack measured is the installed one: Python 3.13.13, kokoro-onnx 0.5.0, onnxruntime 1.28.0, phonemizer-fork 3.3.2 (GPL-3.0), espeakng-loader 0.2.4, numpy 2.5.2.

## Method

Model files: `kokoro-v1.0.onnx` (325,532,387 bytes) and `voices-v1.0.bin` (28,214,398 bytes) in `~/.local/share/kokoro`, the ones the app uses. Voices: `am_puck`, `bm_george`, `bf_isabella` and `af_sky`.

```sh
cd rust/relay-speech-proto
cargo build --release --locked --target aarch64-apple-darwin
"$HOME/Library/Application Support/relay-runner/services/.venv/bin/python" compare.py \
    --out ~/relay-runner-investigations/RR-479-speech-samples
```

`compare.py` does the rest, and each stage can be repeated on its own with `--stage`:

- **Render.** One process per stack and voice over the whole corpus, each under `/usr/bin/time -l`. The stacks take turns voice by voice, so a busy spell on the machine hits them alike. The Python process imports `kokoro_onnx`, builds `Kokoro(model, voices)` and for each sentence calls `tokenizer.phonemize(text, "en-us")` and then `create(phonemes, voice=..., speed=1.0, lang="en-us", is_phonemes=True)`. That is what `create(text, ...)` does inside, split in two so that phonemes and synthesis are timed separately. The Rust process prints the same timings.
- **Load time** is everything before the first sentence can be synthesised. Python: importing `numpy` and `kokoro_onnx`, then the `Kokoro` constructor. Rust: creating the ONNX Runtime session, reading the voice and building the phonemiser.
- **Real-time factor** is the phoneme and synthesis time for the whole corpus divided by the seconds of audio produced. Below 1 is faster than real time.
- **First audio** uses the reply "Sure, I can take a look at that for you." with `am_puck`. Cold is a new process, from launch until its WAV is on disk, five times per stack in turn, with the model already in the disk cache. Warm is the same sentence eleven times in one process with the first discarded, and the figure is the median of the other ten. Warm is what a running bridge does for each reply.
- **Peak memory** is the maximum resident set size that `/usr/bin/time -l` reports for a render process.
- **CoreML** is one more render of the corpus with `am_puck` and `--provider coreml`, which registers the CoreML execution provider with its default options.

### Scheduling priority

The first full pass of these measurements was TBD-FACTOR times too slow for both stacks, and anyone repeating them from a worker will hit the same thing. The orchestrator daemon is a launchd agent with `ProcessType` `Background` (`scripts/relay-orchestrator:344`), so it and every worker it starts run at priority 4, which macOS keeps on the efficiency cores. The app starts its speech bridge with `launchctl submit` (`Sources/relay-runner/Process/ProcessManager.swift:908`), and that job runs at priority 20 on any core. A worker cannot raise itself: `taskpolicy -B` returns success and changes nothing.

The numbers in this report were therefore taken by starting `compare.py` the way the bridge is started, and removing the job when it finished:

```sh
launchctl submit -l com.relay.rr479-measure -o LOG -e LOG -- /bin/sh -c \
    '"$0" "$1" --out "$2"; launchctl remove com.relay.rr479-measure' PYTHON SCRIPT OUT
```

Every record under `runs/` carries the priority it ran at, and all of them say 20. The background-priority pass is kept beside it in `runs-background-priority/`. The audio is the same in both; only the timings differ.

The machine was not idle. The one-minute load average before each run was between TBD-LOADMIN and TBD-LOADMAX, mostly other workers at background priority, and the laptop was on battery. Treat differences of a few percent between the stacks as noise.

### Is the audio path the same?

The two stacks never get the same phonemes, so their audio cannot be compared directly. As a separate check, twelve phoneme strings from the Rust runs (six sentences, `am_puck` and `bf_isabella`) were given to kokoro-onnx with `is_phonemes=True`, and its output was compared with the Rust WAV for the same sentence and voice. The sample counts were identical in all twelve. The waveforms correlate at 0.9965 to 0.9996. For the two sentences where the magnitude spectra were compared as well, those correlate above 0.999.

They are not bit-identical, and that is expected. The model has no random operators, and kokoro-onnx repeats itself exactly. But kokoro-onnx against itself with a different graph-optimisation level or thread count differs by the same amount on those two sentences (waveform correlation 0.996 to 0.998). The prototype links ONNX Runtime 1.31.0 and the Python stack 1.28.0, so the difference is within what ONNX Runtime's own numerics produce, not a porting error in the tokens, the style vector or the trim. This check was run by hand and is not part of `compare.py`.

## Measurements

TBD-MEASUREMENTS

## Licence check

Run from `rust/relay-speech-proto/` with cargo-deny 0.20.2:

```sh
cargo deny --locked check licenses bans sources
```

Result: `bans ok, licenses ok, sources ok`. The allow list is the one in `scripts/rust-licenses`, unchanged, so every GPL-family licence is refused. `deny.toml` also bans by name the crates that bind espeak-ng, because most of them declare a permissive licence for their own code. It makes two exceptions, neither copyleft:

- `webpki-root-certs` (CDLA-Permissive-2.0): Mozilla's root certificates, used only by the `ort-sys` build script to download ONNX Runtime. Not linked into the binary.
- `language-tokenizer` (WTFPL): a dependency `misaki-rs` declares and does not use. It goes away with `misaki-rs` under the recommendation below.

Three further checks on the built binary: `Cargo.lock` holds no espeak or phonemizer crate, `nm` finds no espeak symbol, and `otool -L` lists only system libraries (libc++, libSystem, libobjc, Foundation, CoreFoundation, CoreML). The word "espeak" does occur in the binary, as the text of an error message that `misaki-rs` compiles whether or not its `espeak` feature is on.

The data `loqui-g2p` embeds is permissively licensed according to its `NOTICE`: the misaki lexicons and the two fallback models trained on them are Apache-2.0, the spaCy tokenizer rules are MIT, and the part-of-speech tagger weights are the crate authors' own.

`scripts/rust-licenses --check` still passes for the app's workspace, which this crate is not part of.

## Hardened runtime

A copy of the release binary was signed the way `scripts/build-dmg.sh` signs the helper binaries, with the Developer ID Application identity on this machine:

```sh
codesign --force --timestamp --options runtime --sign "Developer ID Application" relay-speech-proto
```

`codesign -dv` reports `flags=0x10000(runtime)`, the Developer ID authority chain and a secure timestamp. `codesign -d --entitlements -` prints none, and `codesign --verify --strict` passes.

The signed binary then rendered three corpus sentences in each of three configurations: misaki-rs on the CPU, loqui-g2p on the CPU, and loqui-g2p with CoreML. Every run exited 0 and wrote valid 24 kHz mono 16-bit WAVs. So the prototype runs under the hardened runtime with no entitlements. ONNX Runtime is linked statically, so there is no third-party library for library validation to refuse.

Not checked: notarisation of a bundle that contains it, and Gatekeeper on another Mac.

## Phoneme differences

Phonemes were compared for `am_puck`. The Python stack asks espeak-ng for American phonemes for every voice (`lang="en-us"`), and the Rust runs do the same. espeak-ng writes IPA and misaki writes Kokoro's own alphabet, so `compare.py` first rewrites the IPA with the table misaki uses for its own espeak fallback, drops stress marks and spaces, and then takes the edit distance divided by the longer length: 0 is identical, 1 is nothing in common.

| Category | Sentences | Mean distance, loqui-g2p | Mean distance, misaki-rs | Sentences where misaki-rs leaves a word unspoken |
| --- | --- | --- | --- | --- |
| Ordinary replies | 8 | 0.06 | 0.06 | 0 |
| Code identifiers | 6 | 0.06 | 0.17 | 3 |
| File paths | 5 | 0.23 | 0.43 | 5 |
| Numbers | 6 | 0.18 | 0.20 | 1 |
| Dates | 5 | 0.14 | 0.18 | 3 |
| Version strings | 5 | 0.16 | 0.27 | 3 |
| Ticket ids | 5 | 0.23 | 0.23 | 0 |
| Product names | 6 | 0.07 | 0.15 | 4 |
| Unknown words | 6 | 0.08 | 0.43 | 6 |
| Symbols | 5 | 0.18 | 0.25 | 1 |
| All | 57 | 0.13 | 0.23 | 26 |

**misaki-rs without espeak-ng is not usable on its own.** A word outside its lexicon is silently left out of the audio: 38 words in 26 of the 57 sentences. That covers every made-up word, as intended, and also "plugin", "config", "dict", "clippy", "Kokoro", "Xcode", "SQLite", "Tailscale", "Homebrew", "frontmatter", "kubectl", "nginx", "kHz", "ms", times such as "6:06", the URL and most of each file path. "The plugin is called Zorblax, and its mascot is a snarfblat" comes out as "The is called, and its mascot is a". There is no error to catch.

**loqui-g2p speaks every word.** It is a port of the same misaki rules and lexicons (the two crates give identical phonemes on 29 of the 57 sentences) with a small embedded neural model for words outside the lexicon. Against today's espeak-ng output:

Ordinary replies barely differ. The distance of 0.06 is notation: vowel length marks, flapped t, reduced vowels. Kokoro was trained on misaki phonemes, so this notation is the one the model expects.

Better than today:

- "1,492 tests": today "one, four hundred ninety two"; loqui "one thousand four hundred ninety two".
- "the 1990s": today "nineteen hundred ninety z"; loqui "nineteen nineties".
- "$12.50 a month": today "dollar twelve. fifty"; loqui "twelve dollars and fifty cents".
- "2.5 seconds", "Python 3.13": today the point is a pause ("two. five"); loqui says "two point five", "three point one three".
- "I read the report you asked about": today present-tense "reed"; loqui uses the part of speech and says "red".

Worse than today:

- Words the fallback model gets wrong: "plugin" as "ploojin", "Xcode" as "code", "SQLite" as "sklite", "nginx" as "enjinks" (today "engine x"), "kubectl" without its t, and "github" with a "th" sound when it is inside a URL (correct as the word "GitHub").
- Acronyms that today's stack reads as words are spelled out: JSON, YAML, TOML, JIRA, ONNX.
- Paths, URLs and ISO dates lose their separators. Today's stack says "slash", "tilde", "dash" and "hash". loqui says none of them and runs the parts together, so `docs/specs/orchestrator-tickets.md` is one long word followed by "M D", and "2026-11-12" is "twenty twenty six eleven twelve" without a break.

Different, and a matter of taste:

- Numbers are read in pairs: port 7634 is "seventy six thirty four" (today "seven thousand six hundred thirty four"), RR-448 is "R R four forty eight" (today "R R four hundred forty eight"), and 2026 is "twenty twenty six" (today "two thousand twenty six").
- Version strings lose the pauses between parts: "0.5.3" is "zero five three".

loqui-g2p also has a British lexicon, which today's stack does not use even for the two British voices. The listening page has it as a fourth player for `bm_george` and `bf_isabella`. It is an option the port would open, not something needed for parity.

loqui-g2p accepts inline markup, `[word](/phonemes/)`, to override one word's pronunciation, so a short table of corrections can be applied to the text before it is phonemised.

## Listening page

`~/relay-runner-investigations/RR-479-speech-samples/index.html`, with its audio beside it under `audio/` (167 MB in all, outside the repository). Open it in a browser. Each sentence has the phonemes from every stack and a player per voice: today's Python stack, the prototype with misaki-rs, the prototype with loqui-g2p, and for the British voices loqui-g2p with its British lexicon.

The page opens with links to the twelve sentences whose loqui-g2p phonemes are furthest from today's, and marks them in the list:

| Sentence | Distance | Text |
| --- | --- | --- |
| `number-05` | 0.44 | That costs $12.50 a month, or $150 a year. |
| `symbol-01` | 0.35 | Visit https://github.com/pykeio/ort for the source. |
| `date-02` | 0.32 | I'll check again on 2026-11-12. |
| `path-02` | 0.32 | The config lives at ~/Library/Application Support/relay-runner/config.toml. |
| `version-01` | 0.30 | Relay Runner 0.5.3 ships with Python 3.13 and onnxruntime 1.28. |
| `ticket-05` | 0.28 | See PR #212 and issue JIRA-1024 for the details. |
| `path-01` | 0.27 | I edited services/tts_worker.py and Sources/relay-runner/App/RelayAppCommands.swift. |
| `symbol-04` | 0.26 | JSON, YAML and TOML are all supported; CSV isn't. |
| `ticket-01` | 0.25 | RR-448 is done, and RR-479 is in progress. |
| `ticket-04` | 0.25 | Tickets RR-481 through RR-487 are blocked on the gate. |
| `version-02` | 0.23 | We pin ort at 2.0.0-rc.15 and misaki-rs at 0.8.0. |
| `number-04` | 0.22 | The port is 7634 and the timeout is 300 seconds. |

It also lists the 26 sentences where misaki-rs leaves words unspoken. Five more are worth hearing although their distance is small, because one word is wrong or newly right: `unknown-03` (plugin), `product-03` (Xcode), `product-04` (SQLite), `unknown-06` (kubectl, nginx) and `reply-08` (read).

## Limits

- **Nobody has listened to the audio.** Everything this report says about quality comes from reading phonemes. Whether the Rust voice is acceptable is the user's call, on the listening page.
- One machine, busy with other work and on battery, two passes. These are comparisons between stacks under the same conditions, not latency percentiles.
- Timing stops when the WAV is on disk. Playback is not part of the prototype.
- The corpus is hard on purpose: 49 of its 57 sentences are technical: identifiers, paths, numbers, dates, product names and made-up words. Ordinary replies, where the stacks agree most, are a larger share of what the app actually speaks.
- The phoneme distance is approximate, because it depends on a table that rewrites espeak-ng's IPA.
- CoreML was tried with its default options only (NeuralNetwork format, all compute units, no model cache). The MLProgram format, static shapes and a cache directory were not tried.
- The Rust prototype rendered the corpus more than thirty times across the passes without a failure. That is a smoke test of `ort` on macOS, not a soak test.
- Not built, because it is production work: streaming and cancellation, the control socket, the speech player, and notarisation of a bundle containing the binary.

## Recommendation

TBD-RECOMMENDATION
