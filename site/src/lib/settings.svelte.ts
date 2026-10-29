// The replica's settings, with the app's defaults (AppSettings.swift). The Settings window edits them and
// the dictation demo follows them.

/** A shortcut as the browser sees it: a right-hand modifier on its own, or a key with modifiers. */
export interface Shortcut {
    /** `KeyboardEvent.code` of the key. */
    code: string;
    /** Held modifiers for a key combination, in the order macOS shows them. */
    modifiers: ("⌃" | "⌥" | "⇧" | "⌘")[];
    /** The key's name on its keycap ("Right ⌘", "esc", "L"). */
    key: string;
}

export const rightModifiers: Record<string, string> = {
    MetaRight: "Right ⌘",
    AltRight: "Right ⌥",
    ControlRight: "Right ⌃",
    ShiftRight: "Right ⇧",
};

export const rightCommand: Shortcut = { code: "MetaRight", modifiers: [], key: "Right ⌘" };
export const escape: Shortcut = { code: "Escape", modifiers: [], key: "esc" };

export const isModifierKey = (s: Shortcut | null) => !!s && s.modifiers.length === 0 && s.code in rightModifiers;
export const keycaps = (s: Shortcut) => (isModifierKey(s) ? [s.key] : [...s.modifiers, s.key]);
export const title = (s: Shortcut) => keycaps(s).join("");
export const sameShortcut = (a: Shortcut | null, b: Shortcut | null) =>
    !!a && !!b && a.code === b.code && a.modifiers.join() === b.modifiers.join();

export type SpeechModel = "english" | "multilingual";
export type ModelState = { kind: "installed" } | { kind: "absent" } | { kind: "downloading"; fraction: number };
export type CleanupModelState =
    | { kind: "absent" }
    | { kind: "downloading"; fraction: number }
    | { kind: "preparing" }
    | { kind: "installed" };

export interface Replacement {
    id: number;
    original: string;
    replacement: string;
}

export const microphones = [
    { id: "builtin", name: "MacBook Pro Microphone", symbol: "laptop" },
    { id: "studio", name: "Studio Display Microphone", symbol: "display" },
    { id: "airpods", name: "AirPods Pro", symbol: "headphones" },
] as const;

class Settings {
    theme = $state<"auto" | "light" | "dark">("auto");
    recordingWindow = $state<"on" | "off">("on");
    alwaysShow = $state(true);
    toggleShortcut = $state<Shortcut | null>(rightCommand);
    pushToTalk = $state<Shortcut | null>(rightCommand);
    cancelShortcut = $state<Shortcut>(escape);
    /** CGEvent button number: 2 is the middle button, 3 and 4 the side buttons. */
    mouseShortcut = $state<number | null>(null);
    launchAtLogin = $state(false);

    showInDock = $state(false);
    recordOnMenuBarClick = $state(false);
    modelActiveDuration = $state(60);
    silenceRemoval = $state(false);
    normalization = $state(true);
    clipboard = $state<"keep" | "replace">("keep");
    clipboardHistory = $state(false);
    pasteResult = $state(true);
    shiftToSend = $state(false);
    simulateKeypresses = $state(false);
    saveRecordings = $state(false);

    soundEffects = $state(true);
    soundVolume = $state(1);
    whileRecording = $state<"keepPlaying" | "pause" | "mute" | "lower">("pause");
    boostMicrophone = $state(true);
    /** nil in the app: Automatic. */
    microphone = $state<string | null>(null);

    speechModel = $state<SpeechModel>("english");
    models = $state<Record<SpeechModel, ModelState>>({
        english: { kind: "installed" },
        multilingual: { kind: "absent" },
    });
    cleanup = $state(false);
    /** As after turning cleanup on once: the model downloaded and converted. */
    cleanupModel = $state<CleanupModelState>({ kind: "installed" });
    learnCorrections = $state(true);
    words = $state<string[]>(["fetchUserProfile", "FluidAudio", "Kubernetes", "max_retries", "Niamh", "SwiftUI"]);
    replacements = $state<Replacement[]>([
        { id: 1, original: "my email", replacement: "me@example.com" },
        { id: 2, original: "Nyam", replacement: "Niamh" },
    ]);

    /** Cleanup runs: switched on, installed, and with the English model (S1-mini is English only). */
    get cleansUp() {
        return this.cleanup && this.speechModel === "english" && this.cleanupModel.kind === "installed";
    }

    get dictationHint() {
        if (this.pushToTalk) return `Hold ${title(this.pushToTalk)} to dictate`;
        if (this.toggleShortcut) return `Press ${title(this.toggleShortcut)} to dictate`;
        return "No dictation shortcut";
    }

    get microphoneName() {
        const device = microphones.find((m) => m.id === this.microphone) ?? microphones[0];
        return this.microphone === null ? `${device.name} (Automatic)` : device.name;
    }

    get microphoneSymbol() {
        return (microphones.find((m) => m.id === this.microphone) ?? microphones[0]).symbol;
    }
}

export const settings = new Settings();

/** The replica's own state that isn't a setting: which Settings page shows, the sidebar, the demo's mode. */
class Navigation {
    page = $state<"general" | "sound" | "models" | "vocabulary" | "cleanup">("general");
    advanced = $state(false);
    sidebarFolded = $state(false);
    /** What the replica's screen shows. */
    mode = $state<"settings" | "dictation">("dictation");
    /** A shortcut field is listening: the dictation shortcuts don't act meanwhile. */
    recordingShortcut = $state(false);
}

export const navigation = new Navigation();
