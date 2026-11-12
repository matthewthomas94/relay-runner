# RR-448 follow-up: Kokoro speech in Rust, prototype and measurements (RR-479)

Dates: 2026-11-11 to 2026-11-13. Hardware: MacBook Pro (Mac16,1), Apple M4 (4 performance and 6 efficiency cores), 24 GiB, macOS 27.0.1. Branch: `relay/rr-479`.

## Result

**Proceed, with a named mitigation.** Port speech synthesis to Rust on `ort` and `loqui-g2p`, put a pronunciation layer in front of the phonemiser, and keep the Python stack until the user has listened to the samples and accepted the voice. The reasons are in [Recommendation](#recommendation).

- **It works.** The prototype rendered all 57 sentences in all four voices, in 44 renders of the corpus without a failure. Its audio path matches kokoro-onnx. No GPL code is linked and the licence check passes. Signed with the hardened runtime and no entitlements, it starts and synthesises.
- **It is not slower and not heavier.** Median and range over three passes at the speech bridge's priority:

  | Measure | Python today | Rust prototype, loqui-g2p |
  | --- | --- | --- |
  | Load time | 643 ms (533 to 792) | 523 ms (448 to 675) |
  | First audio, new process | 1.49 s (1.25 to 1.83) | 1.02 s (0.94 to 1.23) |
  | First audio, model loaded | 889 ms (670 to 1038) | 643 ms (608 to 696) |
  | Real-time factor over the corpus | 0.39 (0.24 to 0.44) | 0.33 (0.20 to 0.36) |
  | Peak resident memory | 768 MiB (722 to 828) | 693 MiB (661 to 757) |
  | Size on disk | 180 MB of packages, plus the Python interpreter | one 76.2 MB executable |

  Both stacks spend nearly all their time inside ONNX Runtime, so read this as "the port costs nothing", not as "Rust is faster".
- **Pronunciation is the open question.** `misaki-rs` without espeak-ng silently leaves out every word it does not know, which rules it out. `loqui-g2p` speaks every word. Against today's stack it is better at numbers, money and decimals, and worse at some technical words, at acronyms and at the separators in paths, URLs and dates. Those can be corrected before the text reaches the phonemiser. Nobody has listened to the audio yet.
- **CoreML does not help.** It loads in 3.2 to 3.9 s instead of 0.5 s, uses twice the memory and is no faster.

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
- **First audio** uses the reply "Sure, I can take a look at that for you." with `am_puck`. Cold is a new process, from launch until its WAV is on disk, five times per stack in turn in each pass, with the model already in the disk cache. Warm is the same sentence eleven times in one process with the first discarded, which leaves ten timings per stack in each pass. Warm is what a running bridge does for each reply.
- **Peak memory** is the maximum resident set size that `/usr/bin/time -l` reports for a render process.
- **CoreML** is one more render of the corpus with `am_puck` and `--provider coreml`, which registers the CoreML execution provider with its default options.

### Scheduling priority

The first full pass of these measurements was three to four times too slow for both stacks, and anyone repeating them from a worker will hit the same thing. The orchestrator daemon is a launchd agent with `ProcessType` `Background` (`scripts/relay-orchestrator:344`), so it and every worker it starts run at priority 4, which macOS keeps on the efficiency cores. The app starts its speech bridge with `launchctl submit` (`Sources/relay-runner/Process/ProcessManager.swift:908`), and that job runs at priority 20 on any core. A worker cannot raise itself: `taskpolicy -B` returns success and changes nothing.

The numbers in this report were therefore taken by starting `compare.py` the way the bridge is started, and removing the job when it finished:

```sh
launchctl submit -l com.relay.rr479-measure -o LOG -e LOG -- /bin/sh -c \
    '"$0" "$1" --out "$2"; launchctl remove com.relay.rr479-measure' PYTHON SCRIPT OUT
```

That was done three times. Passes 1 and 2 ran back to back on 12 November on battery, and pass 3 on 13 November on mains power. Their records are in `runs-pass-1/`, `runs/` (pass 2, the one the listening page and `results.json` are built from) and `runs-pass-3/`. Each record carries the priority it ran at, and all of them say 20. The background-priority pass is kept beside them in `runs-background-priority/`; it predates that field.

The audio does not depend on the pass. All 855 WAVs of pass 3, from every stack including CoreML, are byte-identical to the ones on the listening page. Only the timings differ.

The machine was never idle. The one-minute load average before a render was between 4.1 and 21.6, mostly other workers at background priority. The renders of a pass run one after another, so two stacks are never measured under exactly the same conditions. Treat a difference of ten percent between the stacks as noise.

### Is the audio path the same?

The two stacks never get the same phonemes, so their audio cannot be compared directly. As a separate check, twelve phoneme strings from the Rust runs (six sentences, `am_puck` and `bf_isabella`) were given to kokoro-onnx with `is_phonemes=True`, and its output was compared with the Rust WAV for the same sentence and voice. The sample counts were identical in all twelve. The waveforms correlate at 0.9965 to 0.9996. For the two sentences where the magnitude spectra were compared as well, those correlate above 0.999.

They are not bit-identical, and that is expected. The model has no random operators, and kokoro-onnx repeats itself exactly. But kokoro-onnx against itself with a different graph-optimisation level or thread count differs by the same amount on those two sentences (waveform correlation 0.996 to 0.998). The prototype links ONNX Runtime 1.31.0 and the Python stack 1.28.0, so the difference is within what ONNX Runtime's own numerics produce, not a porting error in the tokens, the style vector or the trim. This check was run by hand and is not part of `compare.py`.

## Measurements

All figures are from the three passes at priority 20. A cell is the median, with the lowest and highest value in brackets.

| Measure | Python: kokoro-onnx, espeak-ng | Rust: loqui-g2p | Rust: misaki-rs | Values per cell |
| --- | --- | --- | --- | --- |
| Load time | 643 ms (533 to 792) | 523 ms (448 to 675) | 628 ms (413 to 659) | 12 |
| First audio, cold | 1.49 s (1.25 to 1.83) | 1.02 s (0.94 to 1.23) | 0.98 s (0.95 to 1.11) | 15 |
| First audio, warm | 889 ms (670 to 1038) | 643 ms (608 to 696) | 635 ms (598 to 673) | 30 |
| Real-time factor | 0.39 (0.24 to 0.44) | 0.33 (0.20 to 0.36) | 0.33 (0.21 to 0.38) | 12 |
| Peak resident memory | 768 MiB (722 to 828) | 693 MiB (661 to 757) | 662 MiB (614 to 710) | 12 |

Every one of the 45 render processes exited 0 and wrote all 57 sentences.

### Load time

| Part | Python | Rust: loqui-g2p |
| --- | --- | --- |
| Importing `numpy` and `kokoro_onnx` | 269 ms (235 to 349) | none |
| Creating the ONNX Runtime session | 379 ms (298 to 453), the `Kokoro` constructor | 397 ms (337 to 490) |
| Reading the voice | inside the constructor | under 1 ms |
| Building the phonemiser | not timed separately | 138 ms (110 to 184) |

The session takes the same time in both. Rust saves the imports and spends about half of that on loading loqui-g2p's lexicon and models. `misaki-rs` builds in 112 ms (57 to 133).

### First audio

The sentence is "Sure, I can take a look at that for you." in `am_puck`. The Python stack makes 2.01 s of audio from it and the prototype 1.86 s, because the phonemes differ.

- **Cold.** A new Rust process has the WAV on disk about half a second sooner: 1.02 s against 1.49 s. That is about the import time above plus starting the interpreter. It matters when the bridge starts or restarts, not on each reply.
- **Warm.** The prototype took 608 to 696 ms in all thirty timings. The Python stack took 670 to 1038 ms, and its median moved between passes: 889, 992 and 759 ms. Per second of audio that is 0.34 to 0.35 for Rust and 0.38 to 0.49 for Python.

A short sentence costs more per second of audio than the corpus average, in both stacks. The figure also moves with what else the performance cores are doing: one hand-run of the warm test for the prototype, at priority 20 before pass 1, gave 403 to 473 ms.

### Real-time factor

One cell per render of the whole corpus:

| Voice | Stack | Audio | Pass 1 | Pass 2 | Pass 3 |
| --- | --- | --- | --- | --- | --- |
| `am_puck` | Python | 256 s | 0.26 | 0.39 | 0.24 |
| `am_puck` | loqui-g2p | 228 s | 0.30 | 0.32 | 0.20 |
| `am_puck` | misaki-rs | 202 s | 0.29 | 0.33 | 0.21 |
| `bm_george` | Python | 285 s | 0.38 | 0.38 | 0.25 |
| `bm_george` | loqui-g2p | 263 s | 0.33 | 0.34 | 0.30 |
| `bm_george` | misaki-rs | 238 s | 0.34 | 0.34 | 0.23 |
| `bm_george` | loqui-g2p, British | 263 s | 0.34 | 0.33 | 0.34 |
| `bf_isabella` | Python | 246 s | 0.40 | 0.41 | 0.38 |
| `bf_isabella` | loqui-g2p | 226 s | 0.35 | 0.36 | 0.33 |
| `bf_isabella` | misaki-rs | 205 s | 0.38 | 0.35 | 0.33 |
| `bf_isabella` | loqui-g2p, British | 227 s | 0.34 | 0.35 | 0.35 |
| `af_sky` | Python | 249 s | 0.40 | 0.39 | 0.44 |
| `af_sky` | loqui-g2p | 228 s | 0.36 | 0.34 | 0.32 |
| `af_sky` | misaki-rs | 205 s | 0.35 | 0.35 | 0.33 |

- Both stacks were more than twice as fast as real time in every render, and up to five times as fast. loqui-g2p was lower than Python in 10 of the 12 voice-and-pass pairs.
- The spread within a stack is larger than the gap between the stacks. The values of 0.20 to 0.26 are the renders that started while the machine was quietest (the first of pass 1 and the first five of pass 3, load average 4 to 7); the rest ran with the load average at 7 to 20.
- Phonemes are a small part of it: 5.2 ms a sentence for espeak-ng, 7.5 ms for loqui-g2p and 6.0 ms for misaki-rs, against roughly a second of synthesis. Everything else is ONNX Runtime, which is version 1.28.0 under Python and 1.31.0 in the prototype. So the gap is as likely to come from the runtime version, or from Python's own threads competing with ONNX Runtime's, as from the language. The conclusion that holds is that the port is not slower.
- The Python stack makes about 10% more audio from the same text, because espeak-ng speaks separators and reads numbers out in full. misaki-rs makes the least, because it leaves words out.

### Peak memory

Maximum resident set size from `/usr/bin/time -l`, over the twelve renders of each stack: Python 768 MiB (722 to 828), loqui-g2p 693 MiB (661 to 757), misaki-rs 662 MiB (614 to 710). The "peak memory footprint" the same tool reports is 686, 666 and 606 MiB. The prototype uses about a tenth less. The model is most of it in both: the file alone is 310 MiB.

### Size on disk, and how ONNX Runtime is linked

Rust:

- The release binary is 76,210,000 bytes (76.2 MB) with cargo's default release profile. `strip` brings it to 67,410,784 bytes, and the stripped binary still synthesises. The Developer ID signed copy is 75,785,184 bytes.
- ONNX Runtime 1.31.0 is linked statically. With its `download-binaries` feature, the `ort-sys` build script downloads a prebuilt `libonnxruntime.a` (83.5 MB, with the CoreML provider compiled in) from the `ort` maintainers' server, `https://cdn.pyke.io/0/pyke:ort-rs/ms@1.31.0/aarch64-apple-darwin+coreml.tar.lzma2`, checks it against the SHA-256 recorded in the crate (`4033efca…ed68c`) and caches it under `~/Library/Caches/ort.pyke.io`. So the first build needs the network, and the library is the maintainers' build, not Microsoft's. `ort-sys` also accepts a library built elsewhere through `ORT_LIB_LOCATION`; that was not tried.
- `otool -L` lists only system libraries, so there is nothing else to ship or sign. CoreML is a system framework.
- The binary carries both phonemisers and their data. A production binary would carry one. Its size was not measured.

Python:

- `kokoro-onnx` and the 28 packages it requires take 180 MB in the services venv, summed from the files each package's metadata lists. The largest are onnxruntime (76.7 MB), numpy (32.2 MB), babel (31.4 MB) and espeakng-loader (19.9 MB, the espeak-ng library and its data). The Python 3.13 interpreter is on top of that.

Commands:

```sh
ls -l target/aarch64-apple-darwin/release/relay-speech-proto
strip -o /tmp/relay-speech-proto-stripped target/aarch64-apple-darwin/release/relay-speech-proto
otool -L target/aarch64-apple-darwin/release/relay-speech-proto
strings -a target/aarch64-apple-darwin/release/relay-speech-proto | grep -x '1\.[0-9]*\.[0-9]*'
```

### CoreML

`am_puck` with loqui-g2p, the CPU render beside the CoreML render of the same pass:

| | CPU, passes 1 / 2 / 3 | CoreML, passes 1 / 2 / 3 |
| --- | --- | --- |
| Load time | 0.5 / 0.6 / 0.5 s | 3.9 / 3.2 / 3.5 s |
| Real-time factor | 0.30 / 0.32 / 0.20 | 0.35 / 0.34 / 0.32 |
| Peak resident memory | 694 / 711 / 692 MiB | 1481 / 1576 / 1416 MiB |

CoreML does not help. It is never faster, it takes about three seconds longer to load on every start, most likely because the model is compiled for CoreML each time (no cache directory was set), and it doubles the memory. At background priority the load took 13 s. The provider did take part: all 57 CoreML WAVs differ from the CPU ones (same length in 56, waveform correlation 0.992 to 0.999). How much of the graph it was given was not recorded.

### At background priority

For the record, the pass taken from the worker itself, at priority 4:

| Measure | Python | Rust: loqui-g2p |
| --- | --- | --- |
| Load time, median | 2.1 s | 1.7 s |
| First audio, cold | 5.6 s | 4.5 s |
| First audio, warm | 2.9 s | 2.5 s |
| Real-time factor, median | 1.20 | 1.06 |

Both stacks are slower than real time there. Speech must not be started from a process that inherits the daemon's background priority, in either language.

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

`~/relay-runner-investigations/RR-479-speech-samples/index.html`, with its audio beside it under `audio/` (about 170 MB in all, outside the repository). Open it in a browser. Each sentence has the phonemes from every stack and a player per voice: today's Python stack, the prototype with misaki-rs, the prototype with loqui-g2p, and for the British voices loqui-g2p with its British lexicon.

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
- One machine, busy with other work, three passes. These are comparisons between stacks under similar conditions, not latency percentiles.
- Timing stops when the WAV is on disk. Playback is not part of the prototype.
- The corpus is hard on purpose: 49 of its 57 sentences are technical: identifiers, paths, numbers, dates, product names and made-up words. Ordinary replies, where the stacks agree most, are a larger share of what the app actually speaks.
- The phoneme distance is approximate, because it depends on a table that rewrites espeak-ng's IPA.
- CoreML was tried with its default options only (NeuralNetwork format, all compute units, no model cache). The MLProgram format, static shapes and a cache directory were not tried.
- The Rust prototype rendered the corpus 44 times across the four passes without a failure. That is a smoke test of `ort` on macOS, not a soak test.
- Not built, because it is production work: streaming and cancellation, the control socket, the speech player, and notarisation of a bundle containing the binary.

## Recommendation

**Proceed, with a named mitigation: `loqui-g2p` behind a pronunciation layer, and the user's ear as the gate.**

What the port gives:

- No GPL code in the speech path. `phonemizer-fork` and espeak-ng go, and with them the licence question RR-448 raised.
- One self-contained executable of at most 76 MB in place of a Python interpreter and 29 packages (180 MB). It runs signed under the hardened runtime with no entitlements and has no library of its own to sign.
- About half a second less before the first audio of a new process. Per reply, speed and memory are level or slightly better.

What it does not give: a faster voice. Synthesis time is ONNX Runtime's in both stacks. The case for the port is licensing and packaging, not latency.

How to do it:

1. **Use `ort` on the CPU with `loqui-g2p`.** Drop `misaki-rs`: without espeak-ng it silently leaves words out. Do not enable CoreML.
2. **Put a pronunciation layer in front of the phonemiser.** This is the mitigation. It is text in and text out, in our own code:
   - speak or pause at the separators in file paths and URLs, and break ISO dates and version strings into parts, which today's stack does and loqui-g2p does not;
   - a table of overrides in loqui-g2p's inline markup for the words its fallback model gets wrong ("plugin", "Xcode", "SQLite", "nginx", "kubectl", "github" inside a URL) and for acronyms that should be read as words (JSON, YAML, TOML);
   - a decision on numbers read in pairs: fine for years, doubtful for port numbers and ticket ids.
3. **Keep the corpus as a regression test.** Commit the expected phonemes for it, so that an upgrade of `loqui-g2p` cannot change a pronunciation unnoticed.
4. **Gate the switch on listening.** Nobody has heard these samples. Before the Python speech stack is removed, the user listens to the page, starting with the twelve flagged sentences and the five named beside them, and accepts the voice. If ordinary replies sound worse than today, do not proceed; nothing in the phonemes suggests they will, and the phonemes are what this report has.

To settle before production, none of it blocking:

- `ort` 2.0.0 is still a release candidate. Keep it pinned exactly.
- The ONNX Runtime library comes prebuilt from the `ort` maintainers' server. Decide whether to keep that, checked by the pinned hash, or to build or vendor the library and pass it with `ORT_LIB_LOCATION`.
- `loqui-g2p` is at 0.4.0, and the licences of its embedded data are taken from its `NOTICE`. Confirm them at the source before shipping.
- Notarisation of an app bundle containing the binary has not been tried.
- Start the speech process the way the bridge is started today. At the daemon's background priority either stack is slower than real time.
