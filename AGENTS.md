# AGENTS.md

Guidance for anyone (human or agent) changing Localflow. `README.md` covers what the app does and how to
install it; `bench/README.md` covers how the models were chosen and measured. This file covers how the
code is meant to stay.

## What Localflow is, and is not

A menu-bar dictation app for Apple Silicon Macs: hold a key, speak, release, and the text is pasted at
the cursor. English, or 25 European languages with the multilingual model; offline once its speech model
is downloaded. Optionally (English only), a small local model cleans up the transcript (fillers, spoken
self-corrections, lists), and a vocabulary keeps names and terms spelled right, learning from the user's
own fixes.

Priorities, in order: transcription accuracy and latency on the target Mac, offline and private by
construction, native UX with reliable insertion and low resource use, minimal features.

Out of scope unless explicitly requested: accounts, history, meeting/file transcription, cloud models,
free-form LLM rewriting (tones, styles, modes, custom prompts) beyond the fixed minimal-edit cleanup,
analytics, auto-updaters, plug-in or provider abstractions. Keep it small: before adding a file, type,
protocol or setting, check whether the problem can be solved inside the existing ones.

## Hard rules

- **No network except model downloads the user asks for.** The speech model chosen in the walkthrough or
  Settings › Models (`SpeechModels`) and the optional cleanup model (`RewriteModel`) are downloaded from
  pinned Hugging Face revisions, SHA-256 checked, over ephemeral sessions. `ModelHub.offlineMode` is set
  before anything loads, so FluidAudio never downloads on its own. Don't add dependencies that phone
  home; nothing else touches the network.
- **Never log or persist user text or audio.** Log timings, sizes, device IDs and error descriptions
  only. The one exception is Advanced settings › Save recordings (diagnostics), which is off by default.
  The vocabulary is user data kept in the app folder's `settings.json`, including words learned from
  corrections; to learn them, `CorrectionLearner` reads the field it pasted into for 30 s, in memory
  only, and keeps at most the corrected word. Never log vocabulary entries or field contents.
- **Never block the event-tap thread or the audio render callback.** Every keystroke on the system
  passes through the tap, and audio callbacks run on a realtime thread: no allocation, I/O, CoreAudio
  property queries or waiting on the main actor there.
- **The recording window must never become key or activate the app.** The paste goes to the
  frontmost app; taking focus would send it to us.
- **Zero compiler warnings** under Swift 6 strict concurrency.

## Architecture

```
Sources/LocalflowApp/
  LocalflowApp.swift        App entry, menu bar item (NSStatusItem) + glyph, Dock icon, window setup, --selftest flags
  DictationController.swift State machine: trigger → record → transcribe → paste; model unloading; timings log
  HotkeyMonitor.swift       CGEventTap on its own thread; toggle and push-to-talk shortcuts (modifier keys or
                            key combinations), mouse shortcut, chords, cancel
  AudioRecorder.swift       CoreAudio AUHAL capture, 16 kHz resampling, level meter
  AudioDevices.swift        Input device list and the "Automatic" choice
  AudioProcessing.swift     Optional silence removal and normalization of a finished recording
  SystemAudio.swift         Other audio while recording (pause, mute, lower) and the microphone boost
  Transcriber.swift         ParakeetUnified (English) or ParakeetV3 (multilingual) + closing-period rule
  ParakeetUnified.swift     The English model's pipeline: FluidAudio's features, CoreML encoder, LocalflowEngine's
                            RNNT decoder
  ParakeetV3.swift          The multilingual model's pipeline: FluidAudio's CoreML preprocessor and encoder,
                            LocalflowEngine's TDT decoder, FluidAudio's retries, windows and seam repair
  ShorterWindows.swift      Shorter copies of the speech models' encoders (and v3's preprocessor), derived
  WindowMerge.swift         FluidAudio's merge of overlapping 15 s windows, for both speech models
  SpeechModel.swift         The speech models: pinned file lists, download (shared with RewriteModel), removal
  TextInserter.swift        Pasteboard + synthetic ⌘V, clipboard restore, leading space; typing
  Rewriter.swift            Optional cleanup: S1-mini on Localflow's engine, drafting, output guard
  RewriteModel.swift        Cleanup model download (pinned, checksummed), conversion, removal
  Tokenizer.swift           Qwen2 byte-level BPE, token for token as llama.cpp tokenizes
  Vocabulary.swift          Words + replacements: spelling matcher, replacements, word helpers
  CorrectionLearner.swift   Watches the pasted-into field for 30 s and learns corrected words
  RecordingWindow.swift     Recording window: waveform pill, idle sliver, snapping
  SettingsView.swift        Settings window: sidebar, General (+ Advanced settings), Sound, Models, Cleanup
  VocabularyView.swift      Settings › Vocabulary: entry field, "Replace with…" box, list, CSV import
  Components.swift          Window chrome and shared controls: cards, rows, (i) popovers, device button
  Onboarding.swift          First-run walkthrough: permissions, mic test, shortcut, practice dictation
  AppSettings.swift         Settings in the app folder's settings.json, the app folder, permissions, sounds
Sources/LocalflowEngine/    The cleanup model's engine (C): engine.c (Qwen3 forward pass, NEON and SME kernels),
                            convert.c (F16 download → int8, rotated), gguf.c (file reading); rnnt.c (the speech
                            models' RNNT and TDT decoders); pool.c (the threads of both)
Sources/NowPlaying/         Helper that /usr/bin/perl loads to ask what's playing (built by build-app.sh)
Sources/LocalflowBench/     Offline ASR benchmark harness (not shipped)
bench/                      ASR and cleanup test sets, harnesses, scorers, results; rewrite_harness
                            (the app's Rewriter and engine over the test set), pass_latency (one forward
                            pass on the engine, llama.cpp and MLX), end_to_end (key release to paste
                            through the installed app)
scripts/                    build-app.sh (build/sign/install), dev-signing.sh,
                            speech-model-manifest.py (pinned file lists for SpeechModel.swift)
Resources/                  Info.plist, entitlements, AppIcon.icon (Icon Composer document), Images (the
                            mark and wordmark)
assets/                     The README's logo and the app icon's ribbon (SVG)
site/                       The website (Vite + Svelte): a working copy of the Settings window, menu and
                            recording window, a dictation demo, the README's speed numbers as charts
.github/workflows/pages.yml Builds site/ and publishes it to GitHub Pages
scratch/                    Not part of the repository: the benchmarks' test sets, Python environments and
                            runs (bench/README.md); list it in .git/info/exclude
```

Concurrency layout: UI-facing state is `@MainActor @Observable` (`DictationController`, `AppSettings`,
`RewriteModel`); services with mutable state are actors (`AudioRecorder`, `Transcriber`,
`ParakeetUnified`, `ParakeetV3`, `Rewriter`); Accessibility and spell-checker work is main-actor
(`CorrectionLearner`, `Vocabulary.respell`); state shared with the tap thread or the audio thread lives
behind `Mutex`/`Atomic` (`HotkeyMonitor`, `CaptureBuffer`, `LevelMeter`). The cleanup engine and each
speech model's decoder run on their own threads (`pool.c`: one per performance core, the calling actor's
thread included), synchronized with barriers that spin for 200 µs, then sleep, and C11 atomics: spinning
only, a cleanup took up to 2 s while other processes kept every core busy (bench/README.md, "Cleanup
engine").

## Design decisions (and why)

Change these only with new evidence; update this section when you do.

**Speech model: NVIDIA Parakeet Unified 0.6B (int8) on the Neural Engine via FluidAudio.** On
dictation-style speech it ties Cohere Transcribe 2B, the most accurate model tested, at ~50 ms per
utterance instead of ~150 ms, and it stays at ~45 ms while the GPU is saturated (GPU/MLX models went to
0.7–3 s). FluidAudio is pinned `exact:` with `traits: []` to drop its TTS, diarization and text-
normalization code. The first inference after load is a warm-up; clips under 1 s are padded;
`Transcriber.finalize` adds the closing period Parakeet tends to drop at the end of push-to-talk clips.
Any model change goes through the benchmark workflow below. Localflow runs the English model's offline
pipeline itself (`ParakeetUnified`): FluidAudio's features, encoder, 15 s windows and window merge, but
the RNNT decoder in LocalflowEngine instead of FluidAudio's two CoreML models called per frame and per
token, which took ~35 ms of a dictation on cold cores (now ~3 ms with the same text; ASR after release
p50 87 → 47 ms, bench/README.md), and without FluidAudio's case-duplicate collapse inside single windows,
which turned "Amazing, amazing luck." into "amazing luck.". The decoder's threads are woken as the
encoder starts (on idle cores they took ~6 ms to wake) and wait giving way to other threads, so busy
cores aren't taken from other work. Recordings that don't fill the encoder's 15 s window run on shorter
copies of it, for 4 s and 10.2 s, that `ShorterWindows` derives from the downloaded bundle (same weights,
linked): the encoder masks everything past the recording, so they differ only by fp16 rounding
(transcripts identical but for decision ties, 11 of 4,200 clips, WER unchanged) and took ASR after
release from p50 47 to 33 ms. Each costs a ~8 s compile on first load (in the background; the 15 s window
serves meanwhile) and ~0.6 GB of the system's Neural Engine cache; past 128 encoder frames (10.2 s) a
window was no faster, and a third window would save ~1 ms. For other languages there's Parakeet v3 (25
European languages, recognized as spoken; 5.37 vs 4.33 dictation-like WER in English, so English stays
the recommended model), whose pipeline Localflow runs itself too (`ParakeetV3`): FluidAudio's CoreML
preprocessor and encoder, its retries of windows decoded to nothing and, past 15 s, its silence-aligned
windows, merge and seam repair, ported as they run with `ASRConfig.default`, with a TDT decoder in
`rnnt.c` that takes FluidAudio's decisions, quirks included (a token whose duration passes the last frame
is dropped, 150 tokens at most, the end-of-audio flush). It runs on two threads fewer than the
performance cores: v3's joint is 8× Unified's, and with every core busy 8 threads took 17 ms per decode,
6 took 9 (idle 3.0 vs 3.2). Transcripts matched FluidAudio's but at decision ties (4 of 840 clips, 30 of
4,200; WER 7.95 → 7.97 in English, 8.63 → 8.62 on Common Voice and FLEURS in seven languages,
`bench/build_multilingual_testset.py`, each inside its bootstrap CI). v3's encoder doesn't mask its
subsampling, so a shorter window needs 6 mel frames to spare; at 63 and 127 encoder frames (up to 4.96
and 10.08 s) the windows were bit-identical to the 15 s one on the M4 Pro, where 64 and 128, as fast,
differed by fp16 rounding, and the CPU preprocessor has copies of the same lengths (bit-identical, 6.6 →
3.6 ms after idle; FluidAudio's Swift mel, 8% off, wasn't an option). ASR after release p50 83 → 35 ms
(up to 5 s: 74 → 23 ms), with every core busy 81 → 28 ms. Cleanup is offered only with the English model:
S1-mini was trained on English, and detecting each dictation's language would add latency.

**Speech models are downloads, not part of the app**, so every model can be removed. The walkthrough's
second step picks one (Multilingual preselected when the Mac's languages include one of v3's besides
English) and downloads it while the user sets up the rest; Settings › Models downloads, switches and
removes them, refusing to remove the last one. They live in the app folder's `models`; a model counts as
installed when every pinned file is there at its size (contents are checked at download), and this is
re-checked at each dictation, so a model deleted by hand falls back to another installed one, or to "No
speech model" with Settings › Models opened. A failed download keeps its checked files and resumes on Try
Again. The speech model (and the cleanup model) unload after a chosen idle time (Advanced settings › Model
active duration), 1 minute by default: loading from CoreML's cache took ~60 ms plus the ~60 ms warm-up
(localflow-bench, M4 Pro), and it starts when the recording's feedback appears, so it's done before the
user stops speaking.

**Audio: CoreAudio AUHAL directly, not AVAudioEngine.** AVAudioEngine kept a stale input format after
switching away from the default device and crashed on tap installation. The AUHAL binds to an explicit
device at its native rate; the render callback only copies samples; resampling to 16 kHz happens once at
stop (`AVAudioConverter`, high quality). The unit stays initialized between recordings so a press only
starts I/O, and I/O is stopped after the samples are handed over. Every recording has a session token so a
late `stop` from a cancelled recording can't end the next one.

**Audio processing: normalization on, silence removal off by default** (numbers in bench/README.md).
Normalization lowered WER on every test set, most on quiet and uneven recordings; silence removal only
helps the latency of recordings with long pauses, and alone it can cut speech that is much quieter than
the rest of the recording, so the app always normalizes first.

**Automatic microphone skips Bluetooth headsets.** Measured: a Bose QC45 delivered ~1 s (cold: 3 s) of
digital silence while switching to its call profile, clipping first words, and its 16 kHz call codec cost
accuracy. A recording of pure silence shows "No sound from the microphone" instead of failing quietly.

**Shortcuts: Toggle recording and Push to talk, through a session event tap.** Each is a key combination
or a right-hand modifier (or Fn) on its own, and both are Right ⌘ by default: the same key in both does
both, hold to talk and tap for hands-free. With different keys push to talk only holds, and a modifier
toggle acts when released without another key, so Right ⌥ + C still works. Right-hand modifiers are
detected through their device-dependent flag bits (`TriggerKey.deviceMask`) so the left-hand twin never
triggers. A removed shortcut is stored as `"none"`, so its default doesn't come back. The optional mouse
button (otherMouse events only, so ordinary clicks never pass through the tap) works like the shared key;
the cancel key is Esc by default. The tap is active (not listen-only) only so these can be swallowed:
matched key combinations (with their repeats and release), the mouse button and the cancel key while
recording; everything else passes through. Settings records a shortcut with a local event monitor while
the tap is paused. Events we synthesize carry `HotkeyMonitor.syntheticEventTag`. When macOS disables the
tap, it is re-enabled and the state of held keys is re-read from the hardware.

**Interaction rules** (all in `DictationController`):
- Hold push to talk to talk. With the same key for toggling (the default) and with the mouse button, a
  release within 300 ms switches to hands-free until the next press; a separate toggle key starts and
  finishes hands-free dictation (also with Shift held on top, for "Hold Shift to send").
- The cancel key cancels. Any other key while a modifier-key shortcut is held is a shortcut (e.g. Right
  ⌘ + C): the key passes through and the dictation is discarded.
- Recording starts on key-down; the recording window and start sound wait 200 ms so shortcuts don't flash
  them.
- A 150 ms tail is recorded after release only if speech is still going on, judged against the
  recording's own noise floor.
- A press while the previous dictation is still finishing is queued, not dropped.
- Recordings end on their own after 15 minutes.

**Insertion: paste, not Accessibility.** Pasting works in native, web, Electron and terminal apps, at any
length, and keeps the target's undo. Setting `AXValue` loses undo and fails in many apps; typing
characters is slow. The ⌘V key is resolved for the current keyboard layout, flags are set explicitly so
held modifiers don't leak in, the entry is marked transient for clipboard managers, and the previous
clipboard is restored after 1 s unless the user copied something meanwhile. A leading space is added only
when Accessibility reports a non-space character before the cursor. In Localflow's own windows (the
walkthrough's practice field) the text view is read directly and learning stays off: Accessibility
queries to our own process would have to be answered by the main thread that is waiting for them.
Advanced settings › Text input: the clipboard can keep the dictation instead of being restored,
clipboard managers can be allowed to record it, pasting can be off (the text is only copied, with a
notice), Shift held as a dictation ends presses Return after the paste, and "Simulate keypresses" types
the text as key events that carry the characters themselves (`keyboardSetUnicodeString`), so it works
with any keyboard layout.

**Settings live in an app folder**: `~/Localflow` by default, holding `settings.json` (every setting and
the vocabulary, readable JSON, every field optional so hand edits load), `models` (the cleanup model) and
opt-in `recordings`. Per-Mac state stays in UserDefaults: the folder's location, the microphone, the
walkthrough, the recording window's position. The file is written 0.3 s after the last change and at
quit, read at launch and when the folder changes. Moving the folder moves its contents; choosing a
location that already has a Localflow folder (a backup, another Mac) adopts its settings.

**Sound while recording.** Pause, Mute or Lower (to 30%) other audio while recording, restored afterwards
only if the user didn't change it meanwhile; and the microphone's input volume turned all the way up
while recording. Pause sends MediaRemote's pause/play commands, which any process may; but since macOS
15.4 only Apple's own binaries are told what is playing, so `SystemAudio` asks through `/usr/bin/perl`,
which loads `NowPlaying.dylib` (built by build-app.sh) and prints only whether something plays and its
pid — the trick MediaRemoteAdapter uses (on macOS 27 the app's own process reads "not playing" while
something plays). That way only playback we paused is resumed. Muffling other audio is left out: it
needs a system audio tap and another permission.

**Recording window.** A black pill shows the waveform while recording; under the pointer it opens into
a stop button. With "Always show" (on by default) a translucent sliver stays on screen between dictations
and opens into three buttons with tooltips: cleanup on/off, start dictating, and Settings. It can be
dragged and snaps to the nearest of 17 places per screen. Every state is one layout whose parts move and
fade (`RecordingWindowView`). The closed pill opens when the pointer comes within ~50 pt of it, or anywhere above it at the
top of a screen. Recording window › Off shows only notices such as "No sound from the microphone". The
`NSPanel` is borderless, non-activating and never key, at `.statusBar` level on all Spaces, always dark.
It ignores the mouse except while the pointer is on the pill (a transparent panel that takes the mouse
would block clicks under it), so the pointer is polled 20 times a second while the pill can open: a
global mouse-moved monitor misses moves while Localflow itself is active (Settings open), so the pill
wouldn't open. The hovered button is worked out from the pointer position rather than by
SwiftUI hover tracking.

**Text after transcription, in order:** vocabulary spelling (`Vocabulary.respell`), the optional
cleanup (`Rewriter`), then replacements — last, so the user's replacements always win — then paste,
then `CorrectionLearner` watches the field. A new dictation ends the previous learning session.

**Cleanup: S1-mini by Superwhisper, on the CPU, off by default.** A Qwen3-0.6B fine-tune for exactly this
task (Apache 2.0 plus a naming clause: always call it "S1-mini by Superwhisper"). On 220 synthesized
dictations it cut WER from 9.2% to 2.7% (bench/README.md) — as good as Qwen3.5-4B at 1/70 of the latency;
general models under 4B answered or obeyed dictated questions and prompts, Apple's Foundation Models
included. It gets the model card's exact system prompt and control line, nothing else (it was trained on
nothing else). It runs on Localflow's own engine (below); CPU because the GPU path went 10× slower under
GPU load. Speculative decoding with drafts copied from the transcript, because cleanup mostly copies its
input: `Rewriter.Drafter` follows where the output is in a rule-based guess at the cleanup (fillers
dropped, repeats collapsed), finds its place again after each edit, and drafts short until copying
resumes. That took 8.2 passes per dictation down to 3.7 with identical output where llama.cpp-style
prompt lookup (draft only after a 3-token match) left 70% of passes without a draft; trained drafters
(DFlash, EAGLE) don't exist for this model and would cost a third of a pass at 0.6B.
`Rewriter.isFaithful` rejects outputs that drop a run of real words without a spoken correction cue or
add words: it catches the model's one systematic failure, dropping instruction-like openings of dictated
AI prompts. Failures and rejections paste the uncleaned text. The model loads while the user speaks (~0.1
s) and unloads with the speech model (Advanced settings › Model active duration).

**The cleanup engine: Localflow's own forward pass, not llama.cpp** (`Sources/LocalflowEngine`; numbers
in bench/README.md, "Cleanup engine"). A dictation is ~3.7 passes of 1–300 tokens, where llama.cpp spent
~29% of the time waiting between its ~25 graph nodes per layer, ran leftover rows one at a time and used
Q8_0's per-32 scales, which cap the NEON dot-product kernels at ~64% of peak and make SME useless. A
survey found nothing to adopt (upstream, ik_llama.cpp, KleidiAI and SME engines: no faster for this
shape). The engine does one Qwen3 pass with 8 barriers per layer (Q/K norms, RoPE and the cache stores
done by whoever finishes a head), any number of tokens per sweep over the weights, the last layer's FFN
and the output layer only for the positions whose next token is wanted, guided self-scheduling over
persistent spinning threads, fp16 attention two query heads at a time, and argmax in the engine. Weights
are int8 with one scale per row and activations int8 with one scale per token, so the matrix products are
pure integer: NEON SDOT on every Mac, plus the SME units' int8 outer products on M4 and later (2 threads;
3–4 measured no faster). One scale per token alone cost accuracy (activation outliers: KL to F16 11×
Q8_0's), so `convert.c` rotates the model as in QuaRot: the residual stream by a Hadamard matrix (norm
weights folded into the next matrices), value/output heads by H_128, and the FFN hidden state by blocks
of H_1024 (the one rotation at run time). Top-1 agreement with F16 then equals Q8_0's (99.93%);
SmoothQuant, int8 attention and an int8 embedding measured worse. The F16 download is converted at
install (~2 s) into `s1-mini-2.gguf` (0.92 GB; the number is `LF_FORMAT`) and deleted; the engine maps
that file (89 MB of its own memory) and reads it ahead at load. A dictation's cleanup took p50 37 ms
after 1 s idle, against 84 ms with llama.cpp on the CPU and 78 on Metal, at benchmark WER 2.7%. Measured
and rejected: i8mm (Apple's cores run SDOT and SMMLA at the same rate), KleidiAI (re-quantizes Q8_0 per
row), BLAS, the Neural Engine (~50–100 GB/s, estimated no faster), time-constraint (real-time) threads,
fewer threads than performance cores (other processes preempt one occasionally and the barriers wait, but
7 threads were no faster on average). The tokenizer (`Tokenizer.swift`) reproduces llama.cpp's byte for
byte, down to its hand-written Qwen2 splitter and Unicode 15.1 tables, matching it on 256k test strings.

**Vocabulary: a text matcher plus replacements, not acoustic boosting.** FluidAudio's CTC boosting found
slightly more terms but dropped neighbouring words and turned ordinary words into terms ("cloud
storage" → "Claude storage"), for +100 ms and a second model. `Vocabulary.respell` only fixes spans
that are a term split, joined or cased differently, or that sound alike and contain a word the system
spell checker doesn't know — no false replacements in the benchmark. Replacements are case-insensitive
and match whole words. Settings › Vocabulary keeps both in one alphabetical list and imports CSV files
(a `word` header, an optional `replacement` column, nothing else).

**Learning from corrections:** poll the pasted-into field's text every 0.4 s for 30 s; the session ends
on focus change, timeout, a new dictation, or when the dictated text disappears (a sent chat message),
keeping the last snapshot. Learn only when exactly one word of the dictated text was replaced (or two
merged) by a word that isn't an ordinary lowercase word, isn't a typo of the original, and looks or
sounds like it. The word joins the vocabulary; a replacement for the misheard form is added only when
that form isn't a real word. Secure text fields are never read. Electron apps (Discord, Slack) hide their
fields from Accessibility until a client sets `AXManualAccessibility`, and their tree took ~2 s to
appear, so `CorrectionLearner.exposeFrontmostApp` sets it when a recording starts and the session waits
up to 3 s for the field. VS Code and its forks are skipped: they take the flag for a screen reader and
switch to their screen-reader mode, so learning doesn't work there.

**Windows and menu.** Settings and the first-run walkthrough are translucent windows
(`.underWindowBackground` behind them) with Liquid Glass panels, built from small custom components
(`Components.swift`): `NavigationSplitView` and `Form` draw a floating sidebar and grouped rows that
don't fit, and a `Form` measures every row whenever it's shown (200 vocabulary entries: ~1 s), so lists
are lazy stacks. An empty compact toolbar puts the traffic lights level with the page titles; the hosting
view has no safe areas, so pages lay out the title bar row themselves. The theme thumbnails are macOS's
own, read from System Settings' Appearance extension at run time rather than copied into the app; Theme
(Auto/Light/Dark) sets `NSApp.appearance`. Focus set as a view appears (`onAppear`) doesn't reach an
AppKit text view yet; text fields are focused after a short delay. Pages scroll under their header bar
(`View.scrollBar`) with a progressive blur: eight within-window `NSVisualEffectView`s whose backdrop
layers get a plain gaussian blur through the private `CAFilter` API, each masked to fade out one step
further from the edge, all in one backdrop group so they sample the same content (the system's soft
scroll edge effect blurs an even band with a hard edge instead); without the private filter the bar stays
clear. The sidebar folds to its icons with a click on its edge, where the pointer becomes a hand, set at
every move because the page's scroll view resets it. Localflow is in the Dock only while one of its
windows is open unless Show in Dock is on. The menu bar item is an `NSStatusItem`, not SwiftUI's
`MenuBarExtra`, which can't tell a left click ("Start recording on menu bar click") from a right one; its
glyph is the mark (`Resources/Images/Mark.svg`) drawn by `MenuBarGlyph` 22 pt wide, the top edge of its
flat ends on a pixel row at 2×, as a template image so the menu bar tints it. Round glass buttons use
plain glass, because interactive glass grows under a press.

**First-run walkthrough:** welcome, the speech model, permissions, a microphone test, the shortcut, a
practice dictation into a field of its own, tips. During the microphone and shortcut steps
`DictationController.beginTest` holds a testing phase: trigger presses don't dictate (they only update
`isTriggerHeld`), and the microphone runs for the waveform until the step changes, the window closes, or
5 minutes pass. The practice step uses the real pipeline.

**Signing: a stable self-signed identity.** Ad-hoc signatures change every build and macOS then forgets
the Accessibility and Microphone grants. `scripts/dev-signing.sh` keeps a "Localflow Development"
identity in a dedicated keychain that is deliberately not on the keychain search list, so nothing else
ever prompts for it.

## Code style

- Match the surrounding code: 4-space indentation, lines up to ~120 columns, Swift API naming, `private`
  by default, `Duration`/`ContinuousClock` for time.
- Comments explain *why* (constraints, measurements, platform quirks), not what. Doc-comment types and
  non-obvious members with `///`; keep them short.
- Name tuning constants as `private static let` with a comment saying where the value came from.
- Prefer concrete types over protocols; don't add abstraction for a single implementation.
- Force unwraps only where failure is impossible (e.g. constant audio formats).
- Logging: `Logger(subsystem: "io.github.snaeppi.localflow", category: …)`. Mark only non-sensitive values
  `privacy: .public`; never interpolate transcripts.
- User-facing copy is short, plain and sentence-case: say what happens and name the setting, key or
  number, no hype; setup steps say why they're needed and what happens next. Refer to System Settings
  panes by their current macOS names (see gotchas).

## Workflows

**Build and run.** `scripts/build-app.sh --install` builds release, compiles the icon, signs, copies
to `/Applications/Localflow.app` and relaunches. The app holds no speech model; it downloads the one
chosen in the walkthrough or Settings › Models. `swift build -c release --product Localflow` is a quick
compile check only: the bare binary has no bundle, so it can't show permission prompts, and it reads
the `Localflow` defaults domain, not `io.github.snaeppi.localflow`.

**Verify a change.** There is no unit-test target; verification is the self-tests plus a manual pass.
- With the app quit:
  `open -W --stdout /tmp/st.txt -a /Applications/Localflow.app --args --selftest; cat /tmp/st.txt`
  records 3 s twice through the real pipeline and prints permissions, device, mic start time, levels and
  ASR time.
- `--selftest-keys` replays Right ⌘ + F18 and checks that the chord cancels the recording.
- `--selftest-rewrite CASES OUT` runs vocabulary + cleanup over the cleanup test set (installing the
  model through the real download if needed) and writes outputs and latencies for
  `bench/rewrite_score.py`; compare against the numbers in bench/README.md.
- `--selftest-learn "SENTENCE"` pastes SENTENCE into the frontmost app and reports the correction it
  would learn from the edit you (or a scripted paste target) make within 30 s; nothing is saved.
- Watch timings live:
  `/usr/bin/log stream --level info --predicate 'subsystem == "io.github.snaeppi.localflow"'` (add
  `--level debug` for trigger events). Info and debug messages are not persisted, so start the stream
  before testing and send it to a file.
- Key release to paste, as a user dictates: `bench/end_to_end/build.sh && bench/end_to_end/run.sh` plays
  55 test clips on the speakers into the built-in microphone with real Right ⌘ presses and pastes into a
  scratch window, cleanup on and off (~20 min, aloud; it puts back the settings and volume it changes).
  Run it after changes to the path from release to paste; README.md quotes its medians.
- Manual pass for anything touching input or insertion: hold-to-talk in Notes, Safari and an Electron app
  (Discord, VS Code); tap for hands-free; Esc; Right ⌘ + C on selected text copies without dictating;
  press again right after releasing; switch microphones in Settings. For cleanup and learning: dictate a
  self-correction with cleanup on; fix a misheard name right after a dictation in each of those apps and
  check Settings › Vocabulary. For the walkthrough, quit the app, run
  `defaults write io.github.snaeppi.localflow onboarded -bool false` and open it again.

**Permissions.** They are keyed to bundle ID `io.github.snaeppi.localflow` plus the signing certificate.
Changing either means granting again; `tccutil reset Accessibility io.github.snaeppi.localflow` (or
`Microphone`) clears stale entries.

**Changing the speech model.** Follow `bench/README.md`: build the test set, run every candidate through
`localflow-bench` / `bench/mlx_bench.py`, score with `bench/score.py`, check latency under GPU load, and
ideally re-run the own-voice test (`bench/dictation_script.txt`, `bench/user_manifest.py`). Then add or
change a case of `SpeechModels.Kind` (repository, pinned revision, the file list printed by
`scripts/speech-model-manifest.py`), load it in `Transcriber`, and record the new numbers in
`bench/README.md`. The pipelines as shipped are `localflow-bench parakeet-unified-localflow` and
`parakeet-v3-localflow` (the latter on the app's copy of the model, also with the multilingual test set,
`bench/build_multilingual_testset.py`); a change to `ParakeetUnified`, `ParakeetV3`, `WindowMerge`,
`ShorterWindows` or `rnnt.c` needs their transcripts compared with `parakeet-unified` and `parakeet-v3`
(FluidAudio's) and with the previous run, differences explained (a decision tie: a logit margin far below
the clip's median, in both decoders) and WER no worse. The decoders read the weights at the offsets the
bundles' `model.mil` gives, and the windows are loaded only if they derive to the recorded SHA-256
(CoreML crashes on a graph it can't parse), so another revision of a model means checking those offsets,
comparing the windows' output with the 15 s window's (v3's are bit-identical on the M4 Pro; the log gives
the new digests) and recording the new digests.

**Changing the cleanup model.** Follow the cleanup section of bench/README.md: run candidates through
`bench/rewrite_bench.py` (any model llama-server runs) and the shipped pipeline through
`--selftest-rewrite`, score with `bench/rewrite_score.py`, and check latency with the GPU saturated. Then
update the prompt constants in `Rewriter`, the pinned source, checksum and size in `RewriteModel`, and
the numbers in bench/README.md. Fine-tunes must get their exact training format. The engine handles
Qwen3-shaped models (two query heads per key/value head, head size 128); another architecture means
another forward pass.

**Changing the engine.** Run `bench/rewrite_harness` (the app's Rewriter and engine over the test set,
with pass statistics) before and after (for `pool.c` also the speech benchmark above), diff the
outputs and score them; an output change needs the benchmark no worse and should be explained
(summation order, a new kernel). Threading changes also need a run with every core busy (12 `yes`
processes; `HARNESS_IDLE_MS=1000` idles before each case as between dictations). Changing the file layout
or the conversion means bumping `LF_FORMAT` (`internal.h`) and the number in `RewriteModel.file`, so
installed models are downloaded and converted again rather than refused. SME code goes in functions
marked `target("sme2")` and runs only when `hw.optional.arm.FEAT_SME2` says so; NEON can't run in
streaming mode, and compiling NEON code with SME enabled makes clang emit SVE, which Apple's cores
don't have outside streaming mode.

**App icon.** `Resources/AppIcon.icon` is an Icon Composer document: the tile is the document's linear
gradient fill (#1F2B3D at the top to #0E1621 at 70%, the same in dark mode), and the colour ribbon is one
PNG layer, `ribbon.png`, rendered from `assets/icon-ribbon.svg` with
`rsvg-convert -w 1024 -h 1024 assets/icon-ribbon.svg -o Resources/AppIcon.icon/Assets/ribbon.png`. It's a
PNG because Icon Composer drops SVG masks, which the folds' shading uses; Apple's advice is PNG for
layers SVG can't express, and 1024 px is the largest size macOS draws. The layer has no glass, so the
folds keep their own shading. Preview every appearance with
`"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon --export-image --output-file /tmp/icon.png --platform macOS --rendition Default --width 512 --height 512 --scale 1`
(renditions: `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight`, `TintedDark`). The build
compiles it with `actool`. The website's `site/public/icon.png` and `favicon.png` are the `Default`
rendition at 256 and 64 px.

**Website.** `site/` is served at `snaeppi.github.io/localflow`, built and published by
`.github/workflows/pages.yml` on pushes to `main` that touch it; `cd site && pnpm install && pnpm dev`
serves it locally, and CI runs `pnpm check && pnpm build`. Its Settings window, menu bar menu and
recording window copy the app's (`SettingsView`, `VocabularyView`, `Components`, `RecordingWindow`,
`StatusItem`) with the same copy, sizes and defaults: change them together. Icons are Lucide's, the
theme thumbnails are drawn, and the start and stop sounds are Web Audio stand-ins (macOS's own can't be
shipped). The dictation demo follows `DictationController`'s interaction rules and replays dictations
from the cleanup test set (Kokoro TTS) with the app's outputs and meter levels for them
(`src/lib/demo/clips.json`, described in `clips.ts`). `src/lib/speed.ts` holds the README's "Speed"
numbers.

**Git.** `main` is the only long-lived branch on `github.com/snaeppi/localflow`. Work on a branch, keep
commits focused with an imperative subject and a body that explains why, and merge by fast-forward.

## Gotchas

- macOS 27 renamed Privacy & Security › Accessibility to **Device Control and Data Access**;
  `Permissions.accessibilityPaneName` picks the right name.
- In zsh, `log` is a shell builtin; use `/usr/bin/log`.
- After a model is downloaded or the app folder moves, CoreML compiles the model once (~10 s, while the
  status reads "Loading speech model…").
- Secure Keyboard Entry (password fields, some terminals, an open password or keychain dialog) hides
  key-down events from the tap but not modifier changes: the trigger still works, but chords can't be
  detected and `--selftest-keys` fails. `ioreg -l -w 0 | grep SecureInput` names the process.
- Fn as the trigger needs "Press 🌐 key to" set to "Do Nothing" in Keyboard settings.
- `actool` and `ictool` need full Xcode, not just the Command Line Tools.
- The system spell checker knows many names (Niamh, Krzysztof) and accepts CamelCase, so "known word"
  only means "ordinary word" for lowercase words.
- A key combination another app registered as a global hotkey never reaches Settings' shortcut
  recorder: the system hands it to that app.
- `/usr/bin/perl` runs hardened: the NowPlaying helper must be given by absolute path, and it must be
  signed (build-app.sh signs it with the app's identity before sealing the bundle).
