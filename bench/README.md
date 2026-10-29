# Speech model benchmarks

How Localflow's speech model was chosen, measured on the target machine: MacBook Pro, Apple M4 Pro
(12 cores, 24 GB), macOS 27, October 2026.

**Result: NVIDIA Parakeet Unified 0.6B (CoreML int8, Neural Engine, via FluidAudio 0.17.7).** On
dictation-style speech it is statistically tied with the most accurate model tested (Cohere Transcribe
2B) at a third of the latency, it uses almost no RAM, and its latency doesn't move when the GPU is busy.

## Test set

`build_testset.py` samples 70 clips of 2–25 s from each of six Open ASR Leaderboard test sets
(`hf-audio/open-asr-leaderboard`): 420 clips, 48.7 min, mean 7 s — push-to-talk length.

| subset | what it is |
|---|---|
| Common Voice | read sentences, many accents and microphones; references keep punctuation and case |
| LibriSpeech test-other | read audiobook speech, the harder half |
| VoxPopuli | European Parliament speeches, accented English |
| GigaSpeech | podcasts and YouTube, spontaneous |
| Earnings22 | earnings calls, accented, numbers and jargon |
| AMI (headset) | meetings, very disfluent |

"Dictation-like" below means Common Voice + LibriSpeech-other + VoxPopuli (210 clips): deliberate,
complete sentences rather than conversation.

**Multilingual test set** (for Parakeet v3): `build_multilingual_testset.py` samples 30 clips of 2–25 s
from each of two read-speech test sets in seven of v3's languages: Swedish, Finnish, German, French,
Spanish, Polish and Russian. 420 clips, 60.1 min, mean 8.6 s, 41 over 15 s. Both datasets are pinned to a
revision; the references keep case and punctuation.

| subset | what it is |
|---|---|
| Common Voice 17 (`cv-*`) | read sentences, many speakers and microphones, mean 5.5 s (`fixie-ai/common_voice_17_0`) |
| FLEURS (`fleurs-*`) | read Wikipedia sentences, one recording per sentence, mean 11.6 s (`google/fleurs`) |

## Metrics

- **WER**: pooled per subset after the Whisper English normalizer (as on the leaderboard), or Whisper's
  basic normalizer (lowercase, punctuation, symbols and bracketed text removed, diacritics kept) on the
  multilingual set; "avg" is the mean over subsets. Paired bootstrap (2,000 resamples) for differences.
- **PnC WER**: WER without normalization on Common Voice (and FLEURS on the multilingual set), so
  punctuation and capitalization errors count — what you'd actually have to fix by hand.
- **Latency**: wall-clock per clip for the transcription call only (audio already in memory), after a
  warm-up.
- **Memory**: process footprint (and MLX peak). Neural Engine weights live outside the process, so CoreML
  footprints look small; the whole app idles at ~48 MB.

## Results

| engine (runtime) | avg WER | dictation-like WER | PnC WER | p50 latency | ≤5 s / 5–10 s / 10–25 s clips | memory |
|---|---|---|---|---|---|---|
| **Parakeet Unified 0.6B** (CoreML, ANE) | 7.32 | **4.33** | 13.8 → **12.4**¹ | **51 ms** | 43 / 53 / 72 ms | ~40 MB + ANE |
| Cohere Transcribe 2B 4-bit (MLX, GPU) | 6.59 | 4.24 | 10.3 | 143 ms | 95 / 147 / 247 ms | 2.0 GB |
| Cohere Transcribe 2B 8-bit (MLX, GPU) | 6.68 | — | 8.9 | 153 ms | 101 / 156 / 266 ms | 2.9 GB |
| Cohere Transcribe 2B int8 (CoreML, ANE)² | 6.71 | — | 9.2 | 609 ms | 556 / 628 / 774 ms | 0.6 GB + ANE |
| Granite Speech 4.1 2B 4-bit LM (MLX, GPU) | 6.50 | — | 8.3 | 463 ms | 299 / 513 / 744 ms | 6.2 GB |
| Qwen3-ASR 1.7B 8-bit (MLX, GPU) | 7.32 | — | 12.8 | 326 ms | 235 / 344 / 625 ms | 3.6 GB |
| Parakeet Ultra 0.6B (CoreML, ANE) | 7.32 | 5.08 | 14.2 | 47 ms | 40 / 48 / 67 ms | ~25 MB + ANE |
| Parakeet TDT 0.6B v2 (CoreML, ANE) | 7.50 | 5.08 | 13.8 | 44 ms | 40 / 45 / 58 ms | ~25 MB + ANE |
| Parakeet TDT 0.6B v3 (CoreML, ANE) | 7.95 | 5.37 | 13.7 | 44 ms | 39 / 46 / 62 ms | ~20 MB + ANE |
| Phonon-2 (CoreML, ANE) | 8.74 | — | 17.0 | 44 ms | 36 / 47 / 67 ms | ~20 MB + ANE |
| Apple SpeechTranscriber (macOS 27) | 9.62 | 7.90 | 21.8 | 105 ms | 71 / 115 / 218 ms | system |

¹ With Localflow's closing-period rule (see below). ² FluidAudio's port pads every call to a fixed 35 s
window (encoder ~390 ms on the ANE) and decodes at ~10 ms/token; CoreML also spends **~100 s**
recompiling it after every app update (Parakeet: ~9–13 s).

Per-subset WER:

| engine | AMI | CV | Earnings22 | GigaSpeech | LS-other | VoxPopuli |
|---|---|---|---|---|---|---|
| Parakeet Unified | 10.31 | 6.36 | 11.57 | 8.41 | 2.85 | 4.43 |
| Cohere 4-bit (MLX) | 6.35 | 6.08 | 11.34 | 8.65 | 2.57 | 4.56 |
| Granite Speech 4.1 | 8.33 | 5.09 | 9.07 | 9.02 | 2.75 | 4.74 |
| Parakeet v2 | 9.38 | 7.92 | 11.49 | 7.79 | 3.49 | 4.92 |
| Parakeet Ultra | 8.85 | 8.91 | 10.63 | 7.66 | 3.03 | 4.80 |
| Apple SpeechTranscriber | 12.40 | 13.01 | 11.73 | 8.10 | 4.59 | 7.90 |

### Significance (paired bootstrap, 95% CI of the WER difference)

| comparison | set | Δ WER | 95% CI |
|---|---|---|---|
| Parakeet v2 − Cohere 4-bit | all 420 | 0.62 | [0.04, 1.20] |
| Parakeet Unified − Cohere 4-bit | all 420 | 0.53 | [−0.08, 1.26] |
| Granite − Cohere 4-bit | all 420 | −0.08 | [−0.71, 0.56] |
| Parakeet Unified − Cohere 4-bit | dictation-like | 0.06 | [−0.64, 1.01] |
| Parakeet v2 − Parakeet Unified | dictation-like | 0.76 | [0.18, 1.35] |

Cohere's overall edge comes mostly from meetings (AMI) — not what you dictate. On dictation-like speech
Unified and Cohere are indistinguishable, and Unified is clearly better than the other Parakeets.

### GPU contention (decisive)

Same 60 clips while another process saturates the GPU with fp16 matmuls (like a training run):

| engine | idle p50 / p90 | GPU busy p50 / p90 |
|---|---|---|
| Cohere 4-bit (MLX, GPU) | 143 / 173 ms | **1,928 / 3,183 ms** |
| Parakeet v2 (CoreML, ANE) | 44 / 47 ms | 44 / 48 ms |

GPU models become unpredictable whenever the GPU is busy; the Neural Engine is untouched by it.

### Read sentences on two microphones (12 sentences)

| engine | MacBook Pro mic | Bose QC45 (Bluetooth) |
|---|---|---|
| Parakeet Unified | 1.5 % | 15.3 % |
| Cohere 4-bit (MLX) | 1.5 % | 15.8 % |
| Parakeet Ultra | 1.5 % | 15.3 % |
| Granite Speech 4.1 | 3.1 % | 15.3 % |
| Parakeet v2 | 3.6 % | 15.3 % |
| Apple SpeechTranscriber | 5.1 % | 23.5 % |

The remaining built-in-mic "errors" were the reader deviating from the script; every model agreed. The
Bluetooth column is dominated by clipped beginnings: the headset delivers silence for about a second while
it switches to its call profile (measured: 3 s of digital silence on a cold start). Hence Localflow's
"Automatic" microphone prefers the Mac's microphone over Bluetooth headsets.

The one systematic model difference was the closing period: Parakeet Unified dropped it on 4–5 of 12
sentences (the audio stops right at the last word), Cohere never did. Appending a period to multi-word
transcripts that end without punctuation cut PnC WER 13.8 → 12.4 on Common Voice and 7.3 → 5.2 on the
built-in-mic recordings. (Padding the audio with silence instead was inconsistent across microphones.)

### In-app latency

Key release to paste through the installed app, October 2026, M4 Pro (`bench/end_to_end`): a helper
with Localflow's bundle ID and signature holds Right ⌘, plays a clip of the cleanup test set on the
MacBook speakers and releases 0.3 s after it ends; Localflow records from the built-in microphone and
pastes into a plain text view that logs when the text arrives. Every 4th case (55 clips in Kokoro
voices, median 5.3 s, up to 50 s), 2.5 s apart, with the recording window (Always show off), sounds and
normalization on:

| ms | median | p90 | max |
|---|---|---|---|
| Release → paste (the app's log) | 57 | 200 | 227 |
| … with cleanup | 82 | 176 | 403 |
| Key up → text in the field (the helpers' clocks) | 66 | 209 | 235 |
| … with cleanup | 90 | 185 | 413 |
| Release → paste, under 15 s and no release tail (46 dictations) | 57 | 64 | 84 |
| … with cleanup (49 dictations) | 81 | 104 | 159 |

The microphone delivered audio 45–58 ms after the key went down. Medians of the steps after release:
stopping the microphone and resampling 9 ms, normalization 6 ms, ASR 38–39 ms, vocabulary, cleanup and
paste 25 ms (1 ms without cleanup). The p90s are the long recordings (39–50 s: 190–207 ms, 326–403 with
cleanup) and the 150 ms release tail, which fired on 5 of 110 dictations although the key came up 0.3 s
after the clip. Key up → text adds ~9 ms to the app's own clock: the event tap's delivery and the paste
reaching the text view.

It needs the cleanup test set's audio (`rewrite_asr.py`, under "Reproducing the cleanup numbers"), the
app folder at `~/Localflow` and a built-in microphone:

```sh
bench/end_to_end/build.sh && bench/end_to_end/run.sh    # ~20 min; plays the clips aloud
```

### The English model's pipeline (`ParakeetUnified`)

Localflow runs Parakeet Unified's offline pipeline itself instead of FluidAudio's `UnifiedAsrManager`,
for its decoder: FluidAudio decodes the encoder's output with two CoreML models called from a greedy
loop, the joint once per 80 ms frame plus the prediction network and the joint once per token (~130 calls
for a 6–7 s dictation), which took p50 35 ms, p90 50 ms on cores that had been idle (40 clips, 1 s idle
before each; 22 ms back to back). LocalflowEngine's `rnnt.c` does the same math on the CPU: the bundles'
fp16 weights read in place, fp32 arithmetic (the CoreML models compute in fp16), the LSTM units and the
vocabulary split over the performance cores, the joint evaluated two frames at a time (1, 4 and 8
measured slower), in p50 2.9 ms, p90 5.8 ms on the same encoder output. Its threads are woken as the
encoder starts: from sleep on idle cores they took ~6 ms to wake, and cores already running also did the
LSTM twice as fast. While they wait they give way to other threads (Mach's priority depression, 1 ms at a
time), so they keep idle cores awake without taking busy ones: plain spinning through the encoder cost
them their priority when every core was busy, and the decode went to p50 180 ms. Everything else is
FluidAudio's: its mel features (computed only for the frames that hold audio, the same values), the int8
encoder, 15 s windows overlapping by 2 s, and its window merge, ported.

On the test set the decoder gave the same tokens on 437 of 439 windows (four of them emitted a token
one frame earlier); the other two are near ties, an added comma and an added "Like," that the
reference has. The merge port gave the same transcripts on all 19 clips over 15 s. One deliberate
difference: FluidAudio also collapses case-only duplicate words ("…have Have a…", meant for window
seams) inside single windows, where they are the speaker's. It did so on 4 test clips and was wrong on
3 — "Amazing, amazing luck." became "amazing luck." (reference "amazing amazing luck."), "No no
that's" became "no that's" — so Localflow collapses only across seams.

| pipeline | avg WER | AMI | Earn | Giga | dictation-like | PnC | p50 / p90 back to back | p50 / p90 after 1 s idle | p50 / p90 / max, cores busy |
|---|---|---|---|---|---|---|---|---|---|
| FluidAudio `UnifiedAsrManager` | 7.32 | 10.31 | 11.57 | 8.41 | 4.33 | 13.79 | 48 / 66 ms | 87 / 109 ms | 153 / 200 / 221 ms |
| `ParakeetUnified` | **7.26** | **10.00** | 11.65 | **8.28** | 4.33 | 13.79 | **31 / 35 ms** | **47 / 52 ms** | **43 / 58 / 84 ms** |

Clips over 15 s (two or more windows) went from 168 to 83 ms after idle. The other subsets'
transcripts are identical. "Cores busy": 12 `yes` processes, 1 s idle before each clip, first 60
clips. Reproduce with `localflow-bench parakeet-unified-localflow` (the app's file, linked into the
harness) against `parakeet-unified`; `BENCH_IDLE_MS=1000` for the idle columns.

### Shorter encoder windows

The encoder's bundle is compiled for a 15 s window (1501 mel frames), and a 3 s dictation paid for all of
it: ~43 ms of the ASR after idle. Its graph masks everything past `mel_length` (the input, each of the
subsampling's three convolutions, attention's keys and the convolution modules' inputs), so the frames
that hold audio don't depend on how much padding follows. `ParakeetUnified` also runs copies of the
bundle for 401 and 1021 mel frames (4 s, and 10.2 s = 128 encoder frames), which `ShorterWindows` derives
from the download: the graph's sizes rewritten, the constants built for 1501 frames rebuilt, each layer's
positional term (quantized per position) sliced to the window's relative positions, the description's
shapes changed, the weights linked. CoreML crashed on a graph it couldn't parse, or on missing weights,
instead of throwing, so a window is loaded only if it derives to the recorded SHA-256 and its link is in
place, and one whose last two loads didn't finish is skipped. A window compiles on first load (6–9 s, in
the background; the 15 s window serves meanwhile), loads from the cache in ~80 ms after the 15 s one, and
takes 0.58 GB of the system's Neural Engine cache.

The encoder alone (random input, p50 of 30 runs back to back and of 8 after 1 s idle):

| window (encoder frames) | 2 s (26) | 4 s (51) | 6 s (76) | 8 s (101) | 10.2 s (128) | 10.3 s (129) | 12 s (151) | 15 s (188) |
|---|---|---|---|---|---|---|---|---|
| back to back | 7.9 ms | 8.8 | 12.1 | 13.4 | 14.0 | 23.7 | 25.7 | 28.0 |
| after 1 s idle | 17.8 ms | 20.7 | 24.5 | 26.6 | 28.4 | 38.3 | 40.6 | 42.9 |

Past 128 encoder frames the time jumps, so the longer window stops there. A third window (4, 7 and
10.2 s) would save ~1 ms on the test set's lengths for another 0.58 GB and load. Long recordings
keep 15 s windows (a different seam would change the merge); their last window uses a short one.

The two windows' outputs differ by fp16 rounding: on 60 clips the median difference was 0.14% of the
frames' RMS (largest 2.0%, at quiet final frames), a tenth of the difference between the Neural Engine
and the CPU running the same 15 s bundle (1.4%), and neither was closer to the CPU's (the short window
was closer on 22 clips, further on 12). The transcripts differ only at decision ties. On the test set
that was 1 of 420 clips: on common_voice-039 the 15 s window chose "sw" over "s" by 0.004 logits, where
the median decision on that clip is won by 9.4, and the 4 s window chose "s" by 0.001 ("Wandsworth"
became "Wandsburg"). Because one clip can't show whether that is chance, both ran on a sample ten times
larger from the same sources (`build_testset.py --per-subset 700 --seed 11`, 4,200 clips, 75,750 words):
11 transcripts differ, one word better ("And" added, as spoken), one worse ("this" became "s"), nine with
the same word errors (punctuation, case, a closing period that `Transcriber.finalize` restores, and two
Common Voice clips whose audio doesn't match the reference); pooled WER 7.570 both.

| pipeline | avg WER, test set / 4,200 | dictation-like | PnC | p50 / p90 after 1 s idle | ≤ 4 s | 4–10.2 s | back to back, 4,200 | cores busy p50 / p90 / max |
|---|---|---|---|---|---|---|---|---|
| 15 s window | 7.26 / 7.47 | 4.33 / 5.38 | 13.79 / 13.93 | 47 / 52 ms | 45 ms | 48 ms | 32 ms | 43 / 58 / 84 ms |
| + 4 s and 10.2 s windows | 7.29 / 7.47 | 4.36 / 5.38 | 13.94 / 13.95 | **33 / 52 ms** | **24 ms** | **34 ms** | **18 ms** | **29 / 44 / 55 ms** |

Clips of 10.2–15 s are unchanged (51 ms); over 15 s, p50 83 → 72 ms.

### The multilingual model's pipeline (`ParakeetV3`)

Localflow runs Parakeet v3's pipeline itself too. FluidAudio's `AsrManager` (`ASRConfig.default`) runs v3
as a CoreML preprocessor on the CPU (audio to mel, in fp16 with int8 DFT and mel weights), the 6-bit
palettized encoder on the Neural Engine, and a greedy TDT decode that calls two more CoreML models per
step: the joint (8,193 token logits, blank included, and 5 for how many frames to advance) for every
frame it evaluates, the prediction network for every token. A step-by-step copy of that pipeline, which
gave FluidAudio's tokens on all 40 clips, timed where its time goes after 1 s idle: preprocessor 6.6 ms,
encoder 35.8 ms, decode loop 35.1 ms (~40 joint and ~25 prediction calls for an 8 s clip), p50 76 ms in
all; back to back 1.3, 26 and 18 ms.

Localflow decodes with LocalflowEngine instead: `rnnt.c` has a TDT loop next to its RNNT one, sharing the prediction
network, joint and threads (v3's have Unified's layout with 8,193 tokens and 5 durations; the bundles'
fp16 weights read in place, fp32 arithmetic). It takes FluidAudio's TdtDecoderV3 decisions, quirks
included: a blank's duration skips frames without updating the prediction; a blank of duration 0, and a
second token at a frame with duration 0, advance by one; a token whose duration reaches past the last
frame isn't emitted; decoding stops after 150 tokens; and the last window then probes its final frames,
up to 10 times until 5 blanks in a row. On the same encoder output it took p50 2.8 ms back to back and
3.2 ms after idle (6 threads), where FluidAudio's calls took 18 and 35 ms, and gave the same tokens on 60
of 60 windows; one took a different duration (3 frames where FluidAudio's fp16 joint said 4, by 0.007
logits where that clip's median duration decision is won by 3.85), which moved later frames but no token.
It runs on two threads fewer than the performance cores: v3's joint is 8× Unified's, so a thread that
other processes preempt holds each barrier longer. Per decode on the same 60 clips:

| decoder threads | back to back p50 / p90 | after 1 s idle | every core busy (12 `yes`) |
|---|---|---|---|
| 8 (all performance cores) | 2.6 / 4.5 ms | 3.0 / 5.5 ms | 16.8 / 30.3 ms |
| 7 | 2.5 / 3.5 ms | 3.0 / 4.1 ms | 13.6 / 22.2 ms |
| **6** | 2.8 / 3.5 ms | 3.2 / 4.2 ms | **9.4 / 16.5 ms** |
| 4 | 3.7 / 4.9 ms | 4.6 / 6.0 ms | 6.9 / 12.3 ms |

Handing out the joint's rows in chunks of 64 from a shared counter instead of fixed slices left 8
threads at 15.3 ms with every core busy: the time goes to preempted threads, not uneven work.

The rest is FluidAudio's, ported as it runs: the retries for a window of sound decoded to nothing
(its issue #909: the padding declared valid to the encoder or the preprocessor, or the audio 0.2 s
shorter, kept if 2 tokens or more come out at a mean probability of 0.7), and for recordings over
15 s its ChunkProcessor: 14.96 s windows every 12.96 s, each start moved to the quietest frame
boundary near silence; the last window ending at the last speech and filled backwards with audio
whose tokens are dropped; the merge (shared with `ParakeetUnified`, `WindowMerge`); and a pass that
decodes gaps of 1.5 s holding speech again. Transcripts were FluidAudio's on 419 of 420 English and
417 of 420 multilingual clips, all 18 and 40 of 41 over 15 s included; each difference is a decision
tie:

| clip | change | margin (fp32) | CoreML's fp16 margin | clip's median |
|---|---|---|---|---|
| earnings22-013 | "postpaid" → "post paid" (worse) | " pa" over "pa" by 0.018 | "pa" by 0.008 | 6.80 |
| cv-fi-021 | closing period dropped | duration 3 over 2 by 0.0012 | 2 | 2.98 |
| fleurs-de-019 (15.2 s) | "Nirarongus" → "Nirarongou" (same errors) | "ou" over "us" by 0.005 | "us" by 0.031 | 12.5 |
| fleurs-pl-000 | "rafi" → "rafie" (better) | "f" over "fi" by 0.003 | tied (0.000), "fi" | 13.3 |

Because these are rare, both ran on the English sample ten times larger (4,200 clips, 75,750 words,
the shorter windows' set): 30 transcripts differ, 8 better, 7 worse and 15 with the same word errors
(formatting). Every one diverges at a decision won by at most 0.029 logits in fp32 (21 tokens, 9
durations), which FluidAudio's fp16 joint takes the other way by at most 0.031 (5 of them exact fp16
ties), on clips whose median decision is won by 0.5–11. Usually a word or a mark changes; once a tie
decided the whole clip: on gigaspeech-679 (2.3 s) a " Ye" by 0.005 over blank at frame 5 made it
"Yeah." instead of "It's proven to be one hour long.", +8 word errors. Pooled WER 7.757 → 7.765
(paired bootstrap of the difference: +0.008, 95% CI [−0.012, +0.036]); on the 420-clip sets +0.027
[0.000, +0.084] in English and −0.016 [−0.050, 0.000] multilingual.

**Shorter windows.** v3's encoder masks less than Unified's: its conformer layers mask everything
past `mel_length`, but its subsampling's three stride-2 convolutions don't, so the last valid
encoder frame reads 7 mel frames past the recording, and through the convolutions' activations past
its end (ReLU of their biases, not zeros) it sees how much padding follows. A window therefore needs
6 mel frames to spare: 8L − 1 for L valid encoder frames (FluidAudio's frame-aligned audio makes L
one more than the frames the decoder walks, and its end-of-audio flush reads that last one). Clips
cut to 49 audio frames (mel length 393) gave the 15 s window's output exactly in a 401-frame window;
cut to 50, with none to spare, it differed by 2.1% of the frames' RMS, 17% on a frame (the 15 s
encoder on the Neural Engine and on the CPU differ by 3.4%).

Exact equality also depends on the window's size. On the M4 Pro, windows of 26, 51, 63, 101, 127
and 129 encoder frames gave the 15 s window's frames bit for bit; those of 64 and 128, the largest
before the steps in the encoder's time, differed by fp16 rounding (median 0.3% of the frames' RMS)
and dropped a comma on one English clip. So v3's windows are 503 and 1,015 mel frames (63 and 127
encoder frames: recordings up to 4.96 and 10.08 s), which gave the 15 s window's transcripts on
every clip of both test sets. Another chip's Neural Engine compiler may tile them differently, and
then they would differ by fp16 rounding as Unified's do. The encoder alone (random input; p50 of 30
runs back to back and of 8 after 1 s idle):

| window (encoder frames) | 2 s (26) | 4 s (51) | 4.96 s (63) | 5.04 s (64) | 5.5 s (70) | 8 s (101) | 10.08 s (127) | 10.16 s (128) | 10.3 s (129) | 15 s (188) |
|---|---|---|---|---|---|---|---|---|---|---|
| back to back | 5.5 ms | 6.5 | 7.1 | 6.8 | 11.1 | 12.2 | 14.8 | 13.0 | 23.2 | 25.9 |
| after 1 s idle | 14.5 ms | 12.3 | 13.0 | 15.0 | 22.2 | 22.4 | 22.5 | 22.3 | 33.9 | 36.5 |

The preprocessor has copies of the same lengths (80,320 and 162,240 samples), derived the same way: its
valid frames read at most 256 samples past the audio, and the copies gave the 15 s one's features bit for
bit on all 354 English clips that fit them (143 fit both). They take it from 6.6 to 3.6 ms after idle for
recordings up to 4.96 s and from 6.5 to 5.1 ms up to 10.08 s (back to back 1.1 to 0.5 and 0.9 ms).
FluidAudio's Swift mel extractor, which Unified's pipeline uses, computes v3's features in fp32 with
exact DFT and mel weights; they differed from the CoreML preprocessor's by 8% of their RMS (median), so
v3 keeps its preprocessor. Each encoder copy compiles on first load (~12 s, in the background) and takes
~0.6 GB of the system's Neural Engine cache; the preprocessor copies run on the CPU.

| pipeline | test set | avg WER | PnC | back to back p50 / p90 | after 1 s idle p50 / p90 | ≤ 4.96 s | 4.96–10.08 s | 10.08–15 s | > 15 s | cores busy p50 / p90 / max |
|---|---|---|---|---|---|---|---|---|---|---|
| FluidAudio `AsrManager` | English | 7.95 | 13.65 | 45 / 64 ms | 83 / 107 ms | 74 ms | 84 ms | 103 ms | 131 ms | 81 / 101 / 161 ms |
| native decoder | English | 7.97 | 13.65 | 31 / 34 ms | 47 / 52 ms | 45 ms | 47 ms | 50 ms | 85 ms | 65 / 87 / 124 ms |
| `ParakeetV3` | English | 7.97 | 13.65 | **19 / 34 ms** | **35 / 51 ms** | **23 ms** | **36 ms** | 50 ms | 86 ms | **28 / 39 / 51 ms** |
| FluidAudio `AsrManager` | multilingual | 8.63 | 12.79 | 51 / 107 ms | 86 / 119 ms | 69 ms | 85 ms | 103 ms | 135 ms | 87 / 127 / 232 ms |
| native decoder | multilingual | 8.62 | 12.79 | 32 / 65 ms | 47 / 57 ms | 45 ms | 46 ms | 48 ms | 84 ms | 59 / 87 / 154 ms |
| `ParakeetV3` | multilingual | 8.62 | 12.79 | **20 / 38 ms** | **35 / 63 ms** | **22 ms** | **35 ms** | 50 ms | 88 ms | **27 / 50 / 108 ms** |

"Native decoder" is LocalflowEngine's decoder with 8 threads and the 15 s window only. "Cores busy":
12 `yes` processes, 1 s idle before each clip, first 60 clips. Reproduce with `localflow-bench
parakeet-v3-localflow` against `parakeet-v3`; `BENCH_IDLE_MS=1000` for the idle columns.

### Audio processing (Advanced settings)

The two options, as `AudioProcessing` implements them: **silence removal** (pauses over 0.5 s shortened
to 0.5 s, judged against each recording's own noise floor) and **dynamic normalization** (80 Hz
high-pass, 500 ms frames brought toward −20 dBFS RMS, at most +30 dB, gains smoothed so pauses aren't
pumped up). Parakeet Unified, average WER over the six subsets, on the test set and variants of it:
everything 25 or 35 dB quieter; pairs of clips with 3 s of faint noise between them ("paused", 210
items); and pairs whose second half is 20 dB quieter ("uneven", 210 items).

| set | off | silence removal | normalization | both (normalized first) |
|---|---|---|---|---|
| test set | 7.32 | 7.29 | **7.00** | 6.97 |
| −25 dB | 7.90 | 7.84 | **7.24** | 7.27 |
| −35 dB | 15.72 | 15.85 | **14.64** | 14.65 |
| paused | 8.09 | 7.84 | **7.75** | 7.82 |
| uneven | 9.92 | 10.90 | **7.98** | 8.00 |

Normalization was better everywhere (paired bootstrap: −0.33 [−0.72, −0.04] on the test set, −1.94
[−3.18, −0.93] on "uneven"; most of it on AMI, 10.3 → 8.7). Silence removal is neutral on normal audio;
on "paused" it cut 23% of the audio and transcription p50/p90 from 107/174 to 66/136 ms, but on its
own it deleted whole quiet sentences in "uneven" — normalizing first prevents that. Hence normalization
on and silence removal off by default, and the app normalizes first. Neither made Parakeet produce
words on pure noise (0 of 120 clips at −80 to −45 dBFS). A 15-minute recording takes ~5 ms (silence
removal) and ~17 ms (normalization) on the M4 Pro.

## Reproducing

From the repository root. Test sets, environments and results go in `scratch/`, which isn't part of the
repository (list it in `.git/info/exclude`).

```sh
# Test set (~90 MB) and scoring environment
uv venv --python 3.12 scratch/asr-research/venv
uv pip install --python scratch/asr-research/venv/bin/python pyarrow fsspec aiohttp huggingface_hub soundfile soxr numpy jiwer whisper-normalizer
scratch/asr-research/venv/bin/python -I bench/build_testset.py scratch/asr-research/testset

# CoreML / Apple engines (models download to ~/Library/Application Support/FluidAudio/Models)
swift build -c release --product localflow-bench
for e in parakeet-unified parakeet-v2 parakeet-v3 parakeet-ultra phonon2 apple-speech cohere; do
  .build/release/localflow-bench $e scratch/asr-research/testset/manifest.jsonl scratch/asr-research/results/$e
done

# MLX engines (see below), then score everything
scratch/asr-research/venv/bin/python -I bench/score.py scratch/asr-research/testset/manifest.jsonl scratch/asr-research/results

# Parakeet v3: the multilingual test set (~115 MB; streams ~3.5 GB of FLEURS archives), FluidAudio's
# pipeline and the app's (on the app's copy of the model, ~/Localflow/models), on both test sets
scratch/asr-research/venv/bin/python -I bench/build_multilingual_testset.py scratch/asr-research/testset-ml
for set in testset testset-ml; do for e in parakeet-v3 parakeet-v3-localflow; do
  .build/release/localflow-bench $e scratch/asr-research/$set/manifest.jsonl scratch/asr-research/results-$set/$e
done; done
```

`localflow-bench` knobs (environment): `BENCH_IDLE_MS` (gap between clips), `BENCH_PAD_MS` /
`BENCH_PAD_NOISE` (trailing padding), `BENCH_BREAKDOWN=1` (Cohere encoder/decoder split),
`BENCH_SILENCE_REMOVAL=1` / `BENCH_NORMALIZE=1` (the app's `AudioProcessing` on each clip before the
timed call, normalization first as in the app; `proc_ms` and `audio_s` per clip).

Your own voice: turn on Advanced settings › Save recordings (they go to `~/Localflow/recordings`),
dictate the lines of `dictation_script.txt`, then build a manifest with `user_manifest.py` and run the
same commands. Turn it off again afterwards.

### MLX engines (`mlx_bench.py`)

Python twin of `localflow-bench` with the same output format, so `score.py` grades both.

```sh
uv venv --python 3.12 scratch/asr-research/mlx-venv
uv pip install --python scratch/asr-research/mlx-venv/bin/python mlx-audio psutil sentencepiece jinja2
for e in cohere-mlx-4bit cohere-mlx-8bit qwen3-asr-8bit granite-speech; do
  scratch/asr-research/mlx-venv/bin/python bench/mlx_bench.py $e scratch/asr-research/testset/manifest.jsonl scratch/asr-research/results/$e
done
```

| engine | HF repo (override with `--model PATH_OR_REPO`) |
|---|---|
| `cohere-mlx-4bit` | `lyzgeorge/cohere-transcribe-03-2026-mlx-4bit` |
| `cohere-mlx-8bit` | `littoralai/cohere-transcribe-mlx-8bit` |
| `qwen3-asr-8bit` | `mlx-community/Qwen3-ASR-1.7B-8bit` |
| `granite-speech` | `divydeep/granite-speech-4.1-2b-mlx-4bit` (autoregressive 4.1 2B) |

- `mlx-community/cohere-transcribe-03-2026-mlx-8bit` is a bf16 checkpoint in a tensor layout mlx-audio
  can't load (it silently produces garbage); the repos above use the mlx-audio layout.
- Decoding: English, greedy, punctuation and capitalization on, no timestamps.
- Run engines one at a time on an otherwise idle machine; latency is wall-clock.

# Transcript cleanup benchmarks

How the optional cleanup pass and the vocabulary were chosen (same machine, October 2026).

**Result: S1-mini by Superwhisper (Qwen3-0.6B fine-tune) on Localflow's own CPU engine (int8,
Hadamard-rotated, NEON + SME), with drafts copied from the transcript, after a spell-checker-guarded
vocabulary matcher and before an output guard.** It cuts the word error rate of raw transcripts from
9.2% to 2.7% at a median ~20 ms back to back (37 ms after 1 s idle) — as accurate as Qwen3.5-4B (3.3%)
at 1/70 of the latency — and doesn't slow down while the GPU is saturated. "Cleanup engine" below has
why it doesn't use llama.cpp.

## Cleanup test set

`rewrite_cases.jsonl`: 220 dictations written for this, each as spoken (with the disfluencies) and as
the ideal minimal-edit text: fillers and stutters removed, spoken self-corrections applied, punctuation
fixed, explicit enumerations as lists, nothing reworded. `must_include` / `must_exclude` strings check
the point of each case (the correction was applied, the term is spelled right, the question wasn't
answered).

| category | n | what it tests |
|---|---|---|
| clean | 40 | already fluent text (many prompts to AI assistants) must come back unchanged |
| filler | 30 | um/uh, repeated words, false starts |
| correction | 40 | "Thursday, no wait, Friday", "or rather", "scratch that"; 8 negatives ("I actually liked it") |
| format | 25 | spoken lists, "new line"; 5 negatives (commas that must stay prose) |
| dictionary | 35 | names, products, jargon, identifiers with a per-case term list; 6 sound-alike negatives |
| injection | 35 | questions and instructions ("ignore previous instructions…") that must be typed, not answered |
| long | 15 | 120–150-word emails, notes and prompts |

`rewrite_asr.py` makes the input realistic: it synthesizes each case with Kokoro TTS (six US/UK voices)
and transcribes it with Localflow's ASR model, so the cleanup sees Parakeet's real output, including its
misrecognitions of special terms ("Superbase", "Nayam", "fetch user profile").

Metrics (`rewrite_score.py`): WER against the reference with case and punctuation ignored, pooled per
category; "checks" = share of `must_include`/`must_exclude` passed; "hijacked" = outputs far (WER > 0.4)
from both the reference and the input: answers, refusals, summaries. References are one person's
judgment, so small WER differences are noise; the checks and hijack counts are the robust signal.

## Models

llama.cpp on the GPU unless noted; general models got the rules prompt (`v1`) or rules plus six
examples (`v2`) from `rewrite_prompts.py`, fine-tunes the exact input format from their model cards.

| engine | WER | checks | hijacked | p50 |
|---|---|---|---|---|
| raw transcript | 9.2 | 54% | 0 | – |
| **S1-mini Q4_K_M** (Superwhisper, 0.6B) | 4.1 | 85% | 5 | 77 ms |
| SpeakoFlow Mini 0.8B Q8_0 | 4.2 | 81% | 3 | 225 ms |
| Handy-editor 350M Q8_0 | 6.1 | 75% | 7 | 56 ms |
| Sotto cleanup 350M Q4_K_M | 7.1 | 71% | 0 | 51 ms |
| Qwen3.5-0.8B Q8_0 (v1) | 8.6 | 63% | 6 | 224 ms |
| Qwen3.5-2B Q4_K_M (v2) | 10.0 | 82% | 11 | 571 ms |
| Qwen3.5-4B Q4_K_M (v2) | 3.3 | 90% | 2 | 1,390 ms |
| Gemma 4 E2B Q4_0 (v2) | 6.0 | 81% | 9 | 267 ms |
| LFM2.5-1.2B Q4_K_M (v1) | 45.7 | 65% | 93 | 200 ms |
| Apple Foundation Models, macOS 27 (v2) | 8.8 | 86% | 9 | 456 ms |
| **shipped pipeline** (matcher → S1-mini Q8_0, CPU → guard) | **2.7** | **90%** | **1** | **40 ms** |

Apple Foundation Models ran through a one-off script with the same prompts, not included here.

Per category (WER / checks):

| engine | clean | filler | correction | format | dictionary | injection | long |
|---|---|---|---|---|---|---|---|
| raw transcript | 2.3 | 23.3 / 60% | 42.2 / 45% | 19.7 / 25% | 10.2 / 48% | 3.4 / 92% | 2.3 / 61% |
| S1-mini alone | 2.3 | 5.8 / 96% | 8.3 / 91% | 5.7 / 81% | 9.7 / 56% | 8.5 / 95% | 0.8 / 100% |
| Qwen3.5-4B (v2) | 1.6 | 4.9 / 97% | 10.6 / 85% | 7.9 / 82% | 2.8 / 92% | 5.5 / 96% | 1.1 / 91% |
| shipped pipeline | 2.3 | 6.1 / 94% | 7.2 / 92% | 5.2 / 82% | 5.4 / 76% | 1.3 / 99% | 0.9 / 98% |

- General models below 4B either answered the dictation ("What's the capital of France?" → "The
  capital of France is Paris."), followed instructions in it, or ignored self-corrections; few-shot
  prompts helped the larger ones. Even Qwen3.5-4B answered one prompt (`{"answer": "100"}`).
- S1-mini's one systematic failure: it drops instruction-like openings of dictated prompts
  ("Translate this sentence to German. The meeting moved…" → "The meeting moved…"). The output guard
  (`Rewriter.isFaithful`: reject deleting a run of > 3 real words with no correction cue nearby, or
  adding > 4 words) caught 3 of 4 and rejected no correct output: 4.1 → 3.7 WER, 5 → 2 hijacks.
- Self-corrections depend on how the speech model punctuated them: "Let's meet at 3, no 4." and "Call me
  on Monday no Tuesday." are corrected, but "Let's meet at 3. No 4." (a pause became a period) is left as
  is, and "Let's meet at 3 no 4." became "Let's meet at 34.", which the guard can't catch.
- Quantization of S1-mini (shipped pipeline): F16 2.8 / 90% / 1, **Q8_0 2.8 / 90% / 1**, Q4_K_M 3.0 /
  89% / 2, Q4_0 3.1 / 87% / 1. Superwhisper publishes F16 and Q4_K_M only, so the app downloads F16 and
  converts it locally ("Cleanup engine").

## Vocabulary

Dictionary category (35 cases):

| approach | WER | checks | cost |
|---|---|---|---|
| raw transcript | 10.2 | 48% | – |
| FluidAudio CTC boosting (parakeet-ctc-110m) | 8.2 | 76% | +106 ms, +100 MB model |
| **text matcher** (`Vocabulary.respell`) | 6.1 | 71% | ~0 ms |
| text matcher → S1-mini | 5.4 | 76% | |
| Qwen3.5-4B with the terms in its prompt | 2.8 | 92% | 1.4 s |

FluidAudio's acoustic boosting found the most terms but rebuilt the text around them: it dropped
neighbouring words ("to Kubernetes" → "Kubernetes"), punctuation, and replaced ordinary words with
terms ("cloud storage" → "Claude storage", "the database" → "the Supabase", "config" → "parseConfig").
The text matcher only touches spans that are the term split, joined or cased differently ("fluid
audio" → FluidAudio, "KPIS" → KPIs) or that sound alike and contain a word the system spell checker
doesn't know ("Versal" → Vercel, "Joquin" → Joaquin, "adorvastatin" → atorvastatin); it made no false
replacement on the negatives. What it can't fix, learned replacements can: the misheard form the user
corrected once ("Nyam") is swapped every time after.

At scale (all 124 test-set terms in one vocabulary, plus 67 more names and acronyms), the matcher
takes 4–12 ms per dictation on the M4 Pro; spoken phrases still join into code identifiers in
prose about code ("the fetch user profile function" → fetchUserProfile), which is the same rule
that writes them right when dictating code. Replacements check for the original as plain text
before compiling their pattern: 100 replacements cost 1 ms instead of 31 ms.

## Drafting

Cleanup mostly copies its input, so the model verifies drafts taken from the transcript. llama.cpp's
prompt lookup drafted only after the last 3 output tokens matched the transcript, so 70% of its passes
(the opening, and after every edit) carried no draft: 8.2 passes per dictation at ~5 ms each for one
token. `Rewriter.Drafter` follows its position in a rule-based guess at the cleanup (fillers dropped
with their comma, repeated words collapsed, sentences capitalized), verifies the opening together with
the transcript, re-finds its place after an edit (skipped words, a 2-token match elsewhere, a later
occurrence of the word), and drafts 4 tokens after a surprise, growing by 2 per copied token up to 20:
3.7 passes, identical outputs in all 220 cases. Drafting 20 tokens every time was worse at p90 (193 ms):
spoken lists and heavily rewritten text reject long drafts at their first token. Trained parallel
drafters (DFlash, EAGLE-3) start at 4B targets; at 0.6B a drafter pass would cost about a third of a
verification pass, for edits that are the hardest tokens to guess.

## Cleanup engine

Localflow's own Qwen3 forward pass (`Sources/LocalflowEngine`) instead of llama.cpp. M4 Pro (8
performance + 4 efficiency cores, two P-clusters with one SME unit each), 220 cases.

| | mean | p50 | p90 | max | WER / checks / hijacks | outputs ≠ llama.cpp |
|---|---|---|---|---|---|---|
| llama.cpp b11723 (an earlier build than below), Q8_0 repacked (harness) | 59.8 ms | 35.4 | 115.9 | | 2.7 / 90% / 1 | – |
| engine, Q8_0 numerics (prototype) | 42.1 | 26.5 | 87.3 | | 2.7 / 90% / 1 | 1 |
| **engine, rotated int8, NEON + SME (harness)** | **32.5** | **20.2** | **71.7** | 233 | **2.7 / 89% / 1** | 6 |
| the same in the app (`--selftest-rewrite`, one run) | | 20 | 71 | 263 | 2.7 / 89% / 1 | 6 |

The six changed outputs are mostly commas (two of them now match the reference); the one lost check
is format-002, a list that both versions get wrong in different ways.

The model loads in ~0.1 s (the engine maps the file and reads it ahead, the tokenizer is built, the
fixed prompt is evaluated) at key-down, while the user speaks, and unloads with the speech model
(Advanced settings › Model active duration). The engine uses 89 MB of its own memory; the model file's
pages (0.6 GB used) are mapped, clean and reclaimable.

Why it is built this way:
- **Nothing to adopt.** Upstream llama.cpp had nothing for this profile; ik_llama.cpp uses the same SDOT
  kernels (~53% of peak on an M2), a per-node barrier, no SME and a 2024 API; no SME kernel anywhere
  (KleidiAI 1.32 included) handles int8 weights with per-32 scales.
- **Where llama.cpp's time went** (macOS `sample`): matrix products 53% at ~60% of the SDOT peak,
  threads waiting between graph nodes 29%, attention 17%. Leftover rows past a multiple of 4 ran one
  at a time through the matrix-vector kernel (5 tokens: 7.3 ms against 5.5 for 4).
- **A pass written for the model**: 8 barriers per layer, every token in one sweep over the weights,
  the output layer only where a prediction is needed. With Q8_0's numerics unchanged this alone was
  1.42× (outputs = llama.cpp's in 219 of 220).
- **Barrier time is mostly other processes**: a spin barrier costs ~0.5 µs with 8 threads (~0.1 ms
  per pass); the rest is a thread briefly preempted. 7 threads cut the waits 3–5× but weren't faster
  on average; time-constraint (real-time) threads didn't help either.
- **With every core busy** (12 `yes` processes; 40 cases, one run each) the spin barriers collapsed:
  a waiting thread kept its core from the preempted one and burnt its own priority (the scheduler
  decays busy threads), so the next barriers waited too. A barrier wait past 200 µs sleeps (`pool.c`;
  50 µs and 1 ms did worse under load), with no change idle:

  | cleanup, cores busy | p50 | p90 | max |
  |---|---|---|---|
  | spinning, 1 s idle before each case (as between dictations) | 54 ms | 604 | 2195 |
  | spinning, back to back | 513 | 2242 | 3124 |
  | spin 200 µs, then sleep; 1 s idle before each | 45–50 | 86–128 | 117–186 |
  | spin 200 µs, then sleep; back to back | 55 | 101 | 146 |
- **Q8_0 caps the kernels** (C microbenchmarks, not included here). Its per-32 scales cost 3 float
  operations per 8 dot products: 64% of the SDOT peak on one core with L1 data, against 84% with one
  scale per row. On SME, int8 outer products with a float fold every 32 / 256 / 1,024 elements ran 62 /
  440 / 910 GMAC/s on one thread and 223 / 1,324 / 2,510 on four (all eight cores' NEON: ~1,100 in the
  engine).
- **One scale per token needs a rotation.** Teacher-forced agreement with the F16 model over the
  test set's reference cleanups (6,025 positions), by activation and weight scaling:

| weights / activations | top-1 | KL (nats/token) |
|---|---|---|
| Q8_0 / Q8_0 (llama.cpp) | 99.934% | 0.00013 |
| one scale per row / per 32 | 99.817% | 0.00023 |
| per 32 / one per token | 99.668% | 0.00153 |
| per row / per token | 99.635% | 0.00149 |
| per row / per token, SmoothQuant α 0.5 | 99.900% | 0.00059 |
| per row / per 256, SmoothQuant α 0.5 | 99.900% | 0.00028 |
| **per row / per token, Hadamard-rotated (QuaRot)** | **99.934%** | **0.00027** |
| the same, int8 Q·K in attention (rotated per head) | 99.884% | 0.00037 |
| the same, int8 embedding | 99.934% | 0.00035 |

  The rotation: the residual stream by H_1024 (RMS norm weights folded into the next matrices first,
  so the norm commutes with it; the embedding and every matrix that reads or writes the stream
  rotated at conversion), value/output heads by H_128, the FFN hidden state by blocks of H_1024 (at
  run time, ~1 µs per token). It needs no calibration data. Shipped: the bold row, fp16 attention,
  F16 embedding.
- **Kernels**: NEON 8 rows × 8 tokens per call (two weight and two activation loads per 16 dot
  products); SME on the last 2 threads from 9 tokens up (below that its 16-token tiles are mostly
  empty), 32 × 32 tiles where there are 32 tokens and ≥ 64 rows per grab; attention for two query
  heads and two tokens per item (fp16 as llama.cpp's CPU flash attention; it is load-bound at ~2
  vector loads per cycle). `-O2` and `-O3` measured the same.
- **Rejected**: i8mm (Apple's cores run SDOT and SMMLA at the same rate); KleidiAI (it re-quantizes
  Q8_0 to one scale per row, keeps extra copies and took 1.1–1.5 s and 0.9–1.4 GB to load in
  llama.cpp); BLAS (it would dequantize every weight to F32 per call); the Neural Engine (researched,
  not built: an estimated 50–100 GB/s of the M4 Pro's 273 GB/s, fixed shapes, and published
  0.5B-class numbers no faster than the CPU here).
- **What's left**: first passes (the transcript plus the opening draft, ~0.33 ms per token) are 53%
  of the time; passes of 1–5 tokens (3.6–4.5 ms) are ~1 ms above the time to read the weights once.

## Reproducing the cleanup numbers

```sh
# TTS + ASR input (Kokoro via mlx-audio; spaCy's en_core_web_sm for misaki)
uv venv --python 3.12 scratch/rewrite/tts-venv
uv pip install --python scratch/rewrite/tts-venv/bin/python mlx-audio "misaki[en]" soxr soundfile \
  "en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
swift build -c release --product localflow-bench     # includes the parakeet-unified-vocab engine
scratch/rewrite/tts-venv/bin/python bench/rewrite_asr.py bench/rewrite_cases.jsonl scratch/rewrite/testset

# A candidate model through llama.cpp (formats: v1 v2 s1 s1-lists handy speakoflow sotto)
llama-server -m MODEL.gguf --port 8090 -c 4096 -np 1 --jinja [-ngl 0] [--spec-type ngram-simple \
  --spec-ngram-simple-size-n 3 --spec-ngram-simple-size-m 20]
python3 bench/rewrite_bench.py scratch/rewrite/testset/cases.jsonl scratch/rewrite/run.jsonl --format s1-lists

# The shipped pipeline, in the app (installs the model first if needed); app quit
open -W --stdout /tmp/r.txt -a /Applications/Localflow.app --args --selftest-rewrite \
  "$PWD"/scratch/rewrite/testset/cases.jsonl "$PWD"/scratch/rewrite/app.jsonl; cat /tmp/r.txt

# The app's Rewriter and engine over the test set, with pass statistics (the model the app installed)
bench/rewrite_harness/build.sh && /tmp/rewrite-harness/harness ~/Localflow/models/s1-mini-2.gguf \
  scratch/rewrite/testset/cases.jsonl scratch/rewrite/harness.jsonl 3

# The same with every core busy, idling 1 s before each case as between dictations
for i in $(seq 12); do (yes > /dev/null &); done
HARNESS_IDLE_MS=1000 /tmp/rewrite-harness/harness ~/Localflow/models/s1-mini-2.gguf \
  scratch/rewrite/testset/cases.jsonl scratch/rewrite/load.jsonl 1; pkill -x yes

# The raw transcript, and the transcript with FluidAudio's CTC boosting (no model, no server)
python3 bench/rewrite_bench.py scratch/rewrite/testset/cases.jsonl scratch/rewrite/raw.jsonl --identity
python3 bench/rewrite_bench.py scratch/rewrite/testset/cases.jsonl scratch/rewrite/ctc.jsonl --identity --input asr_vocab

# Score any of them (needs jiwer); --by-case prints the misses
python3 bench/rewrite_score.py scratch/rewrite/testset/cases.jsonl scratch/rewrite/run.jsonl scratch/rewrite/app.jsonl
```

GPU load for the contention numbers: `bench/gpu_load.py` (fp16 matmuls with MLX, as a training run
would) running for the whole measurement.

# Comparison with other runtimes

The README's "Speed" numbers: Localflow against FluidAudio, llama.cpp and MLX on the same models, on an
M4 Pro (8 performance + 4 efficiency cores, 16-core GPU, 24 GB), macOS 27.0, on power, October 2026.
Versions: FluidAudio 0.17.7, llama.cpp b11887 (built from source with `GGML_NATIVE`, which enables i8mm
and SME; a second build adds KleidiAI v1.32.0, its SME kernels), mlx 0.32.4, mlx-lm 0.32.2, mlx-audio
0.6.1. Each test waited 1 s before every clip or dictation, as between real ones, so cores and GPU have
slowed down as they would; one run each.

**One forward pass** of S1-mini: N tokens after 130 cached, the next token wanted after each of them
(as when a draft is verified); median of 30 back to back, ms. Localflow's engine also picks the next
token inside the pass; llama.cpp's time stops at the logits, MLX's includes an argmax on the GPU.
Weights: Localflow's rotated int8 with one scale per row, Q8_0 for llama.cpp, MLX's 8-bit with a scale
per 64.

| tokens | 1 | 5 | 11 | 21 | 32 | 53 | 128 |
|---|---|---|---|---|---|---|---|
| **Localflow, NEON + SME** | **3.6** | **4.4** | **6.3** | **9.6** | 12.4 | 19.7 | 44.5 |
| Localflow, NEON only (`LF_SME=0`) | 3.6 | 4.6 | 7.1 | 11.1 | 15.1 | 26.2 | 55.8 |
| llama.cpp, CPU (8 threads) | 4.2 | 6.6 | 12.2 | 18.1 | 25.4 | 41.0 | 88.2 |
| llama.cpp + KleidiAI, CPU | 4.1 | 9.0 | 13.3 | 17.2 | 19.4 | 35.3 | 50.7 |
| llama.cpp, Metal | 4.3 | 5.2 | 7.6 | 12.8 | 12.9 | 20.1 | 36.2 |
| MLX (GPU) | 4.5 | 6.0 | 11.0 | 12.1 | 12.4 | 19.7 | **34.8** |

A dictation's cleanup is mostly passes of 1–21 tokens (the shipped harness: 3.7 per dictation, the
first one the transcript with the opening draft, ~53 tokens on average).

**Cleanup per dictation**, the 220 cases. Localflow is the app's `Rewriter` (`bench/rewrite_harness`);
the others are servers driven by `rewrite_bench.py --format s1-lists` (the app's prompt and control
line), with the system prompt cached: llama-server with its n-gram drafting (3-token match, 20 tokens
ahead), mlx_lm.server without drafting (it offers only a separate draft model).

| runtime | mean | p50 | p90 | max | passes per dictation | WER / checks |
|---|---|---|---|---|---|---|
| **Localflow, NEON + SME** | **50 ms** | **37** | **90** | **249** | 3.7 | 2.7 / 89%¹ |
| Localflow, NEON only | 58 ms | 45 | 97 | 283 | 3.7 | 2.7 / 89%¹ |
| llama.cpp, CPU | 118 ms | 84 | 194 | 790 | 8.3 | 3.7 / 86% |
| llama.cpp + KleidiAI, CPU | 118 ms | 91 | 191 | 805 | 8.3 | 3.8 / 86% |
| llama.cpp, Metal | 98 ms | 78 | 170 | 599 | 8.3 | 3.7 / 86% |
| MLX (GPU) | 187 ms | 136 | 222 | 954 | ~28 | 3.7 / 86% |

¹ With the app's vocabulary spelling before the cleanup and its output guard after it, which the
servers don't have: the difference is almost all in the dictionary and injection categories. The
outputs themselves agree: the NEON-only build's are identical to the SME build's, on the clean, filler
and correction categories every runtime scored the same, and elsewhere outputs differ by a word or a
comma here and there (rounding: 201 of 220 of llama.cpp's equal Localflow's, 218 equal between its CPU
and Metal paths).

**Speech**, the 420-clip test set (`build_testset.py`); WER as above, latency from the end of the
recording to the transcript.

| pipeline | avg WER | PnC | p50 | p90 | ≤ 5 s | 5–10 s | 10–25 s | memory |
|---|---|---|---|---|---|---|---|---|
| **Localflow, Parakeet Unified** | 7.29 | 13.94 | **34 ms** | **52** | 25 | 35 | 53 | 96 MB + ANE |
| FluidAudio `UnifiedAsrManager` | 7.32 | 13.79 | 86 ms | 109 | 76 | 89 | 110 | 76 MB + ANE |
| **Localflow, Parakeet v3** | 7.97 | 13.65 | **35 ms** | **51** | 23 | 36 | 51 | 48 MB + ANE |
| FluidAudio `AsrManager`, Parakeet v3 | 7.95 | 13.65 | 83 ms | 108 | 75 | 84 | 107 | 46 MB + ANE |
| mlx-audio, `mlx-community/parakeet-tdt-0.6b-v3` (bf16, GPU) | 8.00 | 13.51 | 101 ms | 173 | 76 | 103 | 163 | 3.3 GB² |

² MLX's peak of active memory; the process grew to 17 GB because mlx-audio leaves MLX's buffer cache
unbounded.

**GPU busy** (`bench/gpu_load.py` for the whole run): every 7th clip (60) and every 4th dictation
(55), against the idle runs' times on the same ones. The load keeps the chip from slowing down
between dictations, so the CPU and Neural Engine paths got faster.

| | idle p50 / p90 | GPU busy p50 / p90 / max |
|---|---|---|
| speech: Localflow, Unified | 35 / 65 ms | 19 / 41 / 70 ms |
| speech: Localflow, v3 | 35 / 93 ms | 21 / 41 / 104 ms |
| speech: FluidAudio, v3 | 83 / 127 ms | 48 / 85 / 180 ms |
| speech: MLX, v3 | 112 / 205 ms | 661 / 1,149 / 1,549 ms |
| cleanup: Localflow | 39 / 85 ms | 22 / 67 / 228 ms |
| cleanup: llama.cpp, CPU | 83 / 194 ms | 61 / 183 / 867 ms |
| cleanup: llama.cpp, Metal | 77 / 153 ms | 758 / 2,356 / 9,327 ms |
| cleanup: MLX | 132 / 240 ms | 1,717 / 3,678 / 16,314 ms |

Reproducing, from the repository root with the test sets as above:

```sh
# llama.cpp from source, static, without the web UI; the KleidiAI build fetches KleidiAI from GitHub
L=scratch/compare/llama.cpp
git clone --depth 1 --branch b11887 https://github.com/ggml-org/llama.cpp $L
for b in build build-kleidi; do
  cmake -S $L -B $L/$b -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF $([ $b = build-kleidi ] && echo -DGGML_CPU_KLEIDIAI=ON)
  cmake --build $L/$b -j --target llama-server llama-quantize llama
done
# Q8_0 from the F16 file the app downloads (RewriteModel's pinned URL)
curl -L --create-dirs -o scratch/compare/models/s1-mini-f16.gguf \
  https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-f16.gguf
$L/build/bin/llama-quantize scratch/compare/models/s1-mini-f16.gguf scratch/compare/models/s1-mini-q8_0.gguf Q8_0

# MLX: the safetensors at a pinned revision, converted to 8 bits
uv venv --python 3.12 scratch/compare/mlx-venv
uv pip install --python scratch/compare/mlx-venv/bin/python mlx-audio mlx-lm psutil sentencepiece jinja2
scratch/compare/mlx-venv/bin/hf download superwhisper/s1-mini --revision 88f6b15896c73bbb13a3b596e0afe8ea0d5150b4 \
  --local-dir scratch/compare/models/s1-mini-hf
scratch/compare/mlx-venv/bin/mlx_lm.convert --hf-path scratch/compare/models/s1-mini-hf \
  --mlx-path scratch/compare/models/s1-mini-mlx-8bit -q --q-bits 8 --q-group-size 64

# One forward pass
LLAMA=$L:build bench/pass_latency/build.sh    # and LLAMA=$L:build-kleidi
/tmp/pass-latency/lf_pass-sme ~/Localflow/models/s1-mini-2.gguf   # and lf_pass-neon
/tmp/pass-latency/llama_pass-build scratch/compare/models/s1-mini-q8_0.gguf 0 8    # 99 for Metal
scratch/compare/mlx-venv/bin/python bench/pass_latency/mlx_pass.py scratch/compare/models/s1-mini-mlx-8bit

# Cleanup per dictation (CFLAGS=-DLF_SME=0 for NEON only)
bench/rewrite_harness/build.sh && HARNESS_IDLE_MS=1000 /tmp/rewrite-harness/harness \
  ~/Localflow/models/s1-mini-2.gguf scratch/rewrite/testset/cases.jsonl scratch/compare/lf.jsonl 1
$L/build/bin/llama-server -m scratch/compare/models/s1-mini-q8_0.gguf --port 8090 -c 4096 -np 1 --jinja -t 8 -tb 8 \
  -ngl 0 --spec-type ngram-simple --spec-ngram-simple-size-n 3 --spec-ngram-simple-size-m 20   # -ngl 99: Metal
python3 bench/rewrite_bench.py scratch/rewrite/testset/cases.jsonl scratch/compare/llama.jsonl --format s1-lists --idle-ms 1000
scratch/compare/mlx-venv/bin/mlx_lm.server --model scratch/compare/models/s1-mini-mlx-8bit --port 8091 \
  --temp 0 --chat-template-args '{"enable_thinking":false}'
python3 bench/rewrite_bench.py scratch/rewrite/testset/cases.jsonl scratch/compare/mlx.jsonl --format s1-lists --idle-ms 1000 \
  --url http://127.0.0.1:8091

# Speech
for e in parakeet-unified parakeet-unified-localflow parakeet-v3 parakeet-v3-localflow; do
  BENCH_IDLE_MS=1000 .build/release/localflow-bench $e scratch/asr-research/testset/manifest.jsonl scratch/compare/asr/$e
done
scratch/compare/mlx-venv/bin/python bench/mlx_bench.py parakeet-v3-mlx scratch/asr-research/testset/manifest.jsonl \
  scratch/compare/asr/parakeet-v3-mlx --idle-ms 1000
```
