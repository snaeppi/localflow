// The demo's dictation, with the app's interaction rules (DictationController.swift): hold to talk, a tap
// under 300 ms switches to hands-free until the next press, the cancel key or a chord discards, the
// recording window and start sound wait 200 ms, and a press while the previous dictation finishes is queued.
// "Speech" is a recording played back; what gets pasted is the app's real output for it.
import { navigation, settings } from "../settings.svelte";
import { playStart, playStop } from "../sounds";
import { scenes, type Clip, type Scene } from "./clips";
import { WaveformBuffer } from "./waveform";

/** Where a press came from: the key both shortcuts share (or the mouse button), push to talk alone, or toggle. */
export type Source = "combined" | "pushToTalk" | "toggle";

const tapThreshold = 300;
const feedbackDelay = 200;
/** The speaker starts a moment after the press, as people do (and as bench/end_to_end does). */
const speechDelay = 350;
/** Release to paste, medians from bench/end_to_end (README "Speed"). */
const pasteDelay = { plain: 57, cleanup: 82 };

class Dictation {
    phase = $state<"idle" | "recording" | "finishing">("idle");
    handsFree = $state(false);
    /** The recording window is up (200 ms into a recording, and while transcribing). */
    shown = $state(false);
    sceneIndex = $state(0);
    /** Seconds of the recording heard so far, for the captions. */
    heard = $state(0);
    /** The text in each scene's field. */
    texts = $state<Record<string, string>>({});
    /** Messages sent with "Hold Shift to send". */
    sent = $state<string[]>([]);
    /** What the last dictation pasted, and for the caption the text with cleanup switched the other way. */
    result = $state<{ pasted: string; cleaned: boolean; partial: boolean; other: string | null } | null>(null);
    notice = $state<string | null>(null);
    lastTranscript = $state<string | null>(null);
    autoplay = $state(false);
    /** The visitor has used the demo: it no longer plays by itself. */
    touched = false;
    /** The on-screen key is down (pressed by the visitor or by autoplay). */
    keyDown = $state(false);
    /** Off until the visitor first uses the demo: browsers don't play sound without a gesture. */
    sound = $state(false);
    waveform = new WaveformBuffer(26);

    private audio: HTMLAudioElement | undefined;
    private since = 0;
    private press: Source = "combined";
    /** A press while finishing, and whether its key came up meanwhile. */
    private pending: { source: Source; released: boolean } | null = null;
    private timers: ReturnType<typeof setTimeout>[] = [];
    private autoplayRun = 0;
    private levelIndex = 0;
    private shiftHeld = false;
    private noticeTimer: ReturnType<typeof setTimeout> | undefined;

    get scene() {
        return scenes[this.sceneIndex];
    }

    selectScene(index: number) {
        this.cancel();
        this.sceneIndex = index;
        this.result = null;
        this.heard = 0;
    }

    // MARK: Triggers

    down(source: Source) {
        if (navigation.recordingShortcut) return;
        if (this.phase === "idle") {
            this.press = source;
            this.begin(source === "toggle");
        } else if (this.phase === "recording" && (this.handsFree || source === "toggle")) {
            this.finish();
        } else if (this.phase === "finishing") {
            this.pending = { source, released: false };
        }
    }

    up(source: Source) {
        if (this.phase === "finishing" && this.pending?.source === source) this.pending.released = true;
        if (this.phase !== "recording" || this.handsFree || source !== this.press || source === "toggle") return;
        if (source !== "pushToTalk" && performance.now() - this.since < tapThreshold) {
            this.handsFree = true;
        } else {
            this.finish();
        }
    }

    /** The menu bar's Toggle Recording and the pill's button: hands-free, or finish. */
    toggle() {
        if (this.phase === "idle") {
            this.press = "combined";
            this.begin(true);
        } else if (this.phase === "recording") {
            this.finish();
        }
    }

    cancel() {
        if (this.phase !== "recording") return;
        this.stopAudio();
        this.clearTimers();
        this.phase = "idle";
        this.shown = false;
        this.handsFree = false;
        this.heard = 0;
    }

    setShift(held: boolean) {
        this.shiftHeld = held;
    }

    // MARK: Recording

    private begin(handsFree: boolean) {
        const scene = this.scene;
        this.phase = "recording";
        this.handsFree = handsFree;
        this.since = performance.now();
        this.heard = 0;
        this.waveform.reset();
        this.levelIndex = 0;
        clearTimeout(this.noticeTimer);
        this.notice = null;
        // Nothing shows for the first 200 ms, so a shortcut like Right ⌘ + C changes nothing.
        this.later(feedbackDelay, () => {
            if (this.phase !== "recording") return;
            navigation.mode = "dictation";
            this.useModel(scene);
            this.result = null;
            this.shown = settings.recordingWindow === "on";
            if (settings.soundEffects && this.sound) playStart(settings.soundVolume);
        });
        this.later(speechDelay, () => {
            if (this.phase === "recording") this.play(scene.clip);
        });
        const step = (now: number) => {
            this.tick(now);
            if (this.phase === "recording") requestAnimationFrame(step);
        };
        requestAnimationFrame(step);
    }

    /** Each recording is in its language: the scene picks the speech model it needs. */
    private useModel(scene: Scene) {
        settings.models[scene.model] = { kind: "installed" };
        settings.speechModel = scene.model;
    }

    private play(clip: Clip) {
        this.stopAudio();
        const audio = new Audio(`${import.meta.env.BASE_URL}audio/${clip.audio}`);
        audio.muted = !this.sound;
        audio.play().catch((error: DOMException) => {
            // Autoplay refused (no gesture yet): play it muted, the captions and waveform still run.
            if (this.audio !== audio || error.name !== "NotAllowedError") return;
            audio.muted = true;
            audio.play().catch(() => {});
        });
        this.audio = audio;
    }

    private stopAudio() {
        this.audio?.pause();
        this.audio = undefined;
    }

    setSound(on: boolean) {
        this.sound = on;
        if (this.audio) this.audio.muted = !on;
    }

    /** Every animation frame while recording: follows the recording and feeds the waveform. */
    private tick(now: number) {
        if (this.phase === "recording" && this.audio) {
            const clip = this.scene.clip;
            const t = this.audio.currentTime;
            this.heard = t;
            const until = Math.min(clip.levels.length, Math.floor(t / 0.02));
            if (until > this.levelIndex) {
                this.waveform.push(clip.levels.slice(this.levelIndex, until));
                this.levelIndex = until;
            }
            if (this.audio.ended) this.audio = undefined;
        } else if (this.phase === "recording") {
            // Before and after the speech: room silence.
            this.waveform.push([0.02]);
        }
        this.waveform.advance(now / 1000);
    }

    /** The speech has played to the end (or never started). */
    get speechDone() {
        return !this.audio && this.heard > 0;
    }

    private finish() {
        if (this.phase !== "recording") return;
        const scene = this.scene;
        const clip = scene.clip;
        const heard = this.audio ? this.audio.currentTime : this.heard;
        const complete = this.speechDone || heard >= clip.duration - 0.05;
        this.stopAudio();
        this.clearTimers();
        this.useModel(scene);
        this.phase = "finishing";
        this.handsFree = false;
        if (settings.soundEffects && this.sound) playStop(settings.soundVolume);
        const outcome = this.transcribe(scene, complete ? clip.words.length : clip.words.filter((w) => w.end <= heard).length);
        const send = this.shiftHeld && settings.shiftToSend && scene.app === "messages";
        this.later(outcome?.cleaned ? pasteDelay.cleanup : pasteDelay.plain, () => {
            this.shown = false;
            if (outcome) {
                this.result = outcome;
                this.lastTranscript = outcome.pasted;
            }
            const done = () => {
                this.phase = "idle";
                this.resumePending();
            };
            if (outcome) this.paste(scene.id, outcome.pasted, send, done);
            else done();
        });
    }

    /** A press that came while finishing starts the next dictation now, hands-free if its key is up. */
    private resumePending() {
        const pending = this.pending;
        this.pending = null;
        if (!pending) return;
        this.press = pending.source;
        this.begin(pending.source === "toggle" || pending.released);
    }

    /** The app's output for the words heard: all of them gives the real result; fewer, a cut transcript. */
    private transcribe(scene: Scene, heardWords: number) {
        if (heardWords === 0) return null;
        const clip = scene.clip;
        const english = scene.model === "english";
        const cleanup = english && settings.cleanup && settings.cleanupModel.kind === "installed" && !!clip.cleaned;
        const transcript = english ? this.unspell(clip, clip.vocabOnly ?? clip.raw) : clip.raw;
        if (heardWords < clip.words.length) {
            const tokens = transcript.split(" ");
            let cut = tokens.slice(0, Math.max(1, Math.round((heardWords / clip.words.length) * tokens.length))).join(" ");
            cut = cut.replace(/[,;:]$/, "");
            if (!/[.?!]$/.test(cut)) cut += ".";
            return { pasted: this.replace(cut), cleaned: false, partial: true, other: null };
        }
        const cleaned = clip.cleaned ? this.unspell(clip, clip.cleaned) : null;
        const pasted = this.replace(cleanup ? cleaned! : transcript);
        const other = english && cleaned ? this.replace(cleanup ? transcript : cleaned) : null;
        return { pasted, cleaned: cleanup, partial: false, other: other === pasted ? null : other };
    }

    /**
     * The recordings' outputs were made with their terms in the vocabulary; a term removed from it goes back
     * to how the speech model wrote it ("fetchUserProfile" → "fetch user profile").
     */
    private unspell(clip: Clip, text: string) {
        if (!clip.dictionary || !clip.vocabOnly) return text;
        const known = new Set(settings.words.map((w) => w.toLowerCase()));
        let out = text;
        for (const span of vocabularySpans(clip.raw, clip.vocabOnly)) {
            const removed = clip.dictionary.some((term) => !known.has(term.toLowerCase()) && span.to.includes(term));
            if (removed && span.from) out = out.replaceAll(span.to, span.from);
        }
        return out;
    }

    /** Replacements, last: whole words, any case, the text as is (Vocabulary.applyReplacements). */
    private replace(text: string) {
        let out = text;
        for (const r of settings.replacements) {
            const original = r.original.trim();
            if (!original) continue;
            const escaped = original.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
            out = out.replace(new RegExp(`(?<![\\p{L}\\p{N}_])${escaped}(?![\\p{L}\\p{N}_])`, "giu"), () => r.replacement);
        }
        return out;
    }

    private paste(sceneId: string, text: string, send: boolean, done: () => void) {
        if (!settings.pasteResult) {
            this.showNotice("Copied to the clipboard");
            return done();
        }
        if (send) {
            this.sent = [...this.sent, text];
            this.texts[sceneId] = "";
            return done();
        }
        if (!settings.simulateKeypresses) {
            this.texts[sceneId] = text;
            return done();
        }
        // Typed as key events, a few milliseconds per character; the dictation finishes when it's in.
        let i = 0;
        const type = () => {
            i = Math.min(text.length, i + 2);
            this.texts[sceneId] = text.slice(0, i);
            if (i < text.length) this.later(8, type);
            else done();
        };
        type();
    }

    showNotice(text: string) {
        clearTimeout(this.noticeTimer);
        this.notice = text;
        this.noticeTimer = setTimeout(() => (this.notice = null), 2500);
    }

    private later(ms: number, run: () => void) {
        this.timers.push(setTimeout(run, ms));
    }

    private clearTimers() {
        this.timers.forEach(clearTimeout);
        this.timers = [];
    }

    // MARK: Autoplay

    /** Plays every scene in turn, holding the key through each recording like a person would. */
    async playAll(from = this.sceneIndex) {
        const run = ++this.autoplayRun;
        this.autoplay = true;
        navigation.mode = "dictation";
        const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
        for (let i = from; ; i = (i + 1) % scenes.length) {
            if (run !== this.autoplayRun) return;
            this.selectScene(i);
            await wait(700);
            if (run !== this.autoplayRun) return;
            this.keyDown = true;
            this.down("combined");
            // Released a moment after the speech ends, however long the audio took to load.
            const start = performance.now();
            const limit = speechDelay + this.scene.clip.duration * 1000 + 8000;
            while (run === this.autoplayRun && !this.speechDone && performance.now() - start < limit) await wait(50);
            await wait(250);
            if (run !== this.autoplayRun) return;
            this.keyDown = false;
            this.up("combined");
            await wait(3400);
        }
    }

    /** The visitor takes over: autoplay stops for good, and the first time, sound comes on. */
    stopAutoplay() {
        if (!this.touched) {
            this.touched = true;
            this.setSound(true);
        }
        this.halt();
    }

    /** Stops autoplay (the demo scrolled away or the tab was hidden); it can start again. */
    halt() {
        if (!this.autoplay) return;
        this.autoplayRun++;
        this.autoplay = false;
        this.keyDown = false;
        this.cancel();
    }
}

/** The spans the vocabulary changed: the vocabulary's spelling (`to`) and the transcript's words (`from`). */
function vocabularySpans(raw: string, vocab: string) {
    const a = raw.split(" ");
    const b = vocab.split(" ");
    const lcs = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
    for (let i = a.length - 1; i >= 0; i--)
        for (let j = b.length - 1; j >= 0; j--)
            lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    const spans: { from: string; to: string }[] = [];
    let from: string[] = [];
    let to: string[] = [];
    const flush = () => {
        if (from.length || to.length) spans.push({ from: from.join(" "), to: to.join(" ") });
        from = [];
        to = [];
    };
    let i = 0;
    let j = 0;
    while (i < a.length || j < b.length) {
        if (i < a.length && j < b.length && a[i] === b[j]) {
            flush();
            i++;
            j++;
        } else if (j < b.length && (i === a.length || lcs[i][j + 1] >= lcs[i + 1][j])) {
            to.push(b[j++]);
        } else {
            from.push(a[i++]);
        }
    }
    flush();
    return spans;
}

export const dictation = new Dictation();
