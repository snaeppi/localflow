<h1>
  <img src="assets/logo.svg#gh-light-mode-only" height="56" alt="Localflow"> <img
  src="assets/logo-dark.svg#gh-dark-mode-only" height="56" alt="Localflow">
</h1>

Yet another dictation app for the macOS menu bar: hold a key, speak, release, and the text is pasted
at the cursor. Speech is transcribed on the Mac with NVIDIA's Parakeet models, in English or in 25
European languages, and a small optional model cleans up the transcript. Your audio and text never
leave the Mac.

[snaeppi.github.io/localflow](https://snaeppi.github.io/localflow/) has a working copy of its Settings
window and replays a few dictations, so you can see how it behaves without installing it.

It is built and tuned on an M4 Pro. The speech models' decoders and the cleanup model run on
Localflow's own C code instead of the usual libraries, and the cleanup model uses the SME matrix units
of M4 and newer chips; other Apple Silicon Macs run the same code on NEON. [Speed](#speed) has the
measurements against FluidAudio, llama.cpp and MLX.

## Using it

- **Hold Right ⌘**, speak, release: the transcript is pasted at the cursor (~60 ms after release, ~80 ms
  with cleanup).
- **Tap Right ⌘** for hands-free dictation; tap again to finish.
- **Esc** cancels.
- Right ⌘ is still your Command key: a shortcut such as Right ⌘ + C works as usual and discards the
  dictation (any other key pressed while holding the trigger does this).
- Right ⌘ is both shortcuts, Toggle recording and Push to talk (Settings › General). Give them different
  keys (a right-hand modifier, Fn or any key combination) to separate tapping from holding: then push to
  talk only records while held, and the toggle key starts and finishes. A mouse button can dictate too
  (hold to talk, click for hands-free), and Esc can be changed.
- The recording window, a small black pill at the top of the screen, shows a live waveform while
  listening; hover it to stop. With **Always show** (Settings › General, on by default) it stays on
  screen between dictations: hover it to start a dictation with the mouse, turn cleanup on or off, or
  open Settings. Drag it anywhere; it snaps to the nearest of 17 places on each screen. Recording window
  › Off hides it.
- The menu bar icon has **Toggle Recording**, **Copy Last Transcript** (in case a paste landed
  somewhere unexpected), Settings, and the microphone and cleanup as submenus. With **Start recording on
  menu bar click** a click on the icon dictates and the menu opens on a right click.
- Settings (menu bar icon › Settings…, or open Localflow again): the microphone is the round button at the
  top right, and a click on the sidebar's edge folds it to its icons. **General** has the theme,
  recording window, shortcuts and launch at login, and leads to **Advanced settings**: Show in Dock, the
  menu bar click, how long the models stay loaded, audio processing (silence removal, normalization), the
  app folder, text input (what your clipboard holds after a paste, clipboard history, paste or only
  copy, Hold Shift to send, typing instead of pasting) and saving recordings. **Sound** has the start and
  stop sounds and their volume, what happens to other audio while you dictate (keep playing, pause, mute
  or lower it), and the microphone volume boost. **Models** has the speech models. Then **Vocabulary**
  and **Cleanup**. The (i) buttons explain each setting.

**Clean up transcripts** (optional, off by default; with the English model only): removes "um"s and
stutters, applies your spoken corrections ("let's meet Tuesday, no wait, Wednesday" → "let's meet
Wednesday"), fixes punctuation and formats spoken lists, without rewording or answering what you
dictate. It uses S1-mini by Superwhisper, a small model made for exactly this, downloaded once from
Hugging Face when you turn it on (1.5 GB; 0.9 GB on disk; Remove deletes it). It runs on the CPU and
adds ~25 ms.

**Vocabulary** (Settings › Vocabulary): words the speech model gets wrong — names, products, jargon —
are spelled your way when the transcript has a variant of them ("fluid audio" → FluidAudio, "Versal" →
Vercel), and replacements swap a word or phrase for your exact text, every time. Type a word and press
⏎ to add it, or ⌘⏎ to type its replacement; the same field searches the list. Import CSV (the button
at the top right) takes a file with a `word` header and an optional `replacement` column: drop it on
the panel or click to choose it, or save the example file to start from. When you fix a misheard name
right after dictating ("Nyam" → Niamh), Localflow adds it for you, so the next dictation gets it right;
turn off **Learn from corrections** to stop that. Learning works in most apps, but not in VS
Code and editors built on it.

Settings, vocabulary and the cleanup model live in **~/Localflow** (Advanced settings › App folder
location moves it; choosing a location that already has a Localflow folder, from a backup or another
Mac, uses its settings). `settings.json` is plain JSON, read at launch.

The microphone defaults to **Automatic**: your system input, except that Bluetooth headsets are skipped
for the Mac's own microphone. Headset mics use a narrow-band call codec, take about a second to switch
profiles (clipping your first words), and drop your headphone audio to call quality while recording.

## Build and install

Requirements: Apple Silicon, macOS 26+, Xcode 26 (Swift 6.2+).

```sh
scripts/build-app.sh --install   # builds, signs, copies to /Applications, launches
```

The app holds no speech model: it downloads the one you choose, and only touches the network for that
and, if you turn on cleanup, for its model. After a model is downloaded CoreML compiles it once (~10 s,
while the status reads "Loading speech model…").

On first launch a short walkthrough lets you choose a speech model, which downloads while you go on:
- **English** (Parakeet Unified 0.6B, 0.6 GB): more accurate for English, and the one cleanup works
  with.
- **Multilingual** (Parakeet v3 0.6B, 0.5 GB): 25 European languages (Bulgarian, Croatian, Czech, Danish,
  Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian,
  Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, Ukrainian),
  recognized as you speak; no cleanup.

Settings › Models downloads the other one, switches between them and removes the one you don't use. The
walkthrough then asks for two permissions, tests the microphone, and lets you try a dictation:
- **Microphone** (prompted).
- **Accessibility**, to detect the shortcut and paste: System Settings › Privacy & Security ›
  **Device Control and Data Access** (called *Accessibility* before macOS 27) › enable Localflow.

`scripts/dev-signing.sh` (run by the build) creates a self-signed "Localflow Development" identity in a
dedicated keychain, so these grants survive rebuilds. It's not in your keychain search list and never
prompts; `scripts/dev-signing.sh --remove` deletes it.

To work on the code, read [AGENTS.md](AGENTS.md): the architecture, the reasons behind the design, and
how to verify and measure a change.

## Why these models

**S1-mini, on the CPU**: on 220 test dictations it cut the error rate of raw transcripts from 9.2% to
2.7% — as accurate as a 4B general model at 1/70 of the latency — while general models under 4B tended
to answer dictated questions instead of typing them; and unlike the GPU, the CPU path doesn't slow down
when another app uses the GPU. Details: [bench/README.md](bench/README.md#transcript-cleanup-benchmarks).

**Parakeet Unified, on the Neural Engine**: on dictation-style speech it ties Cohere Transcribe 2B (the
most accurate model tested), which took ~150 ms per dictation on the GPU, uses almost no RAM, and doesn't
slow down while the GPU is saturated, where GPU models slowed to 0.7–3 s. The multilingual Parakeet v3
runs the same way. Full methodology and numbers: [bench/README.md](bench/README.md).

## Speed

Measured on an M4 Pro (8 performance and 4 efficiency cores, 16-core GPU, macOS 27.0, on power) in
October 2026.

From key release to the text pasted, in the app, over 55 test dictations of 3–53 s played on the
speakers into the built-in microphone with the recording window on: a median of 57 ms, 82 ms with
cleanup. Under 15 s of speech it stayed under 85 ms (160 ms with cleanup); 40–50 s took about 0.2 s
(0.4 s). Method and breakdown: [bench/README.md](bench/README.md#in-app-latency).

The tables compare the two steps that take most of that time with the same models on other libraries,
with 1 s of idle before each dictation, as between real ones. Times are from the end of the recording.
Versions, method and commands: [bench/README.md](bench/README.md#comparison-with-other-runtimes).

Speech to text, 420 clips of 2–25 s from six public test sets:

| | English (Parakeet Unified) | WER | Multilingual (Parakeet v3) | WER |
|---|---|---|---|---|
| Localflow (Neural Engine and CPU) | 34 ms (p90 52) | 7.29 | 35 ms (p90 51) | 7.97 |
| FluidAudio 0.17.7 (Neural Engine) | 86 ms (p90 109) | 7.32 | 83 ms (p90 108) | 7.95 |
| MLX, mlx-audio 0.6.1 (GPU) | | | 101 ms (p90 173) | 8.00 |

WER is the word error rate in %; Localflow's transcripts differ from FluidAudio's only where the model's
choice is a near tie.

Transcript cleanup, S1-mini with 8-bit weights, 220 dictations:

| | median | p90 |
|---|---|---|
| Localflow (CPU, NEON and SME) | 37 ms | 90 ms |
| Localflow, SME off (the code path of chips before M4, on the same M4 Pro) | 45 ms | 97 ms |
| llama.cpp b11887, llama-server with n-gram drafting, CPU | 84 ms | 194 ms |
| llama.cpp b11887, the same on Metal | 78 ms | 170 ms |
| MLX, mlx_lm.server 0.32.2 (GPU; it has no drafting from the prompt) | 136 ms | 222 ms |

Localflow drafts the cleanup from the transcript, so a dictation takes 3.7 passes of the model where
llama.cpp's n-gram drafting took 8.3. Each pass of 1–21 tokens is also faster than llama.cpp's and MLX's
(one token: 3.6 ms against 4.2 on llama.cpp's CPU path; 21 tokens: 9.6 ms against 12.8 on Metal and
12.1 with MLX). From 32 tokens up the GPU catches up: for 128 tokens Metal took 36 ms, MLX 35 and
Localflow 45.

With another app keeping the GPU busy (60 clips and 55 dictations; medians): speech took 19–21 ms
with Localflow, 48 ms with FluidAudio and 661 ms with MLX; cleanup took 22 ms with Localflow, 61 ms with
llama.cpp on the CPU, 758 ms on Metal and 1,717 ms with MLX. The CPU and Neural Engine got faster
because the load kept the chip from slowing down between dictations.

## Privacy

- No network access except the model downloads you ask for (the speech model you choose, and the
  cleanup model if you turn cleanup on), from pinned revisions that must match their SHA-256 sums.
  FluidAudio's own downloader is switched off.
- No telemetry, accounts, or history. The log contains timings only, never transcripts.
- Your settings and vocabulary are stored in `~/Localflow/settings.json`. To learn from your corrections,
  Localflow reads the text field it pasted into for 30 seconds, in memory only (never password fields),
  and keeps only the word you corrected.
- Audio is held in memory for one dictation and discarded. Advanced settings › Save recordings, off by
  default, keeps recordings and their transcripts in the app folder's `recordings`, for testing models
  on your own voice.
- To pause what's playing, Localflow asks macOS whether something is playing (yes or no, and which
  process); it never reads titles.

## Troubleshooting

- `/usr/bin/log stream --predicate 'subsystem == "io.github.snaeppi.localflow"' --level info` shows
  per-dictation timings.
- With the app quit,
  `open -W --stdout /tmp/selftest.txt -a /Applications/Localflow.app --args --selftest; cat /tmp/selftest.txt`
  records 3 s through the real pipeline twice and prints device, microphone start time, levels and ASR
  time — never the transcript.
- Fn as the trigger: set System Settings › Keyboard › "Press 🌐 key to" to "Do Nothing".

## License

Apache 2.0, see [LICENSE](LICENSE). The models aren't part of the repository and keep their own
licenses: NVIDIA's Parakeet models are CC BY 4.0, S1-mini by Superwhisper is Apache 2.0.
