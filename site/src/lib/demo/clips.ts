// Recordings the demo replays. Each is a dictation from the cleanup test set (bench/rewrite_cases.jsonl),
// spoken by Kokoro TTS, with the app's real results: `raw` is Parakeet's transcript, `vocabOnly` the
// transcript after the vocabulary (Vocabulary.swift, with the case's terms), `cleaned` the shipped
// pipeline's output with cleanup on. `levels` are the microphone levels the app's meter computes (one per
// 20 ms); word times are estimates, spread over the voiced part.
import data from "./clips.json";

export interface Clip {
    id: string;
    spoken: string;
    raw: string;
    cleaned: string | null;
    vocabOnly: string | null;
    dictionary: string[] | null;
    duration: number;
    audio: string;
    levels: number[];
    words: { w: string; start: number; end: number }[];
    language?: string;
}

export const clips = Object.fromEntries((data as Clip[]).map((c) => [c.id, c])) as Record<string, Clip>;

export type AppKind = "messages" | "mail" | "notes" | "editor";

export interface Scene {
    id: string;
    title: string;
    app: AppKind;
    clip: Clip;
    /** The speech model the recording needs. */
    model: "english" | "multilingual";
}

export const scenes: Scene[] = [
    { id: "messages", title: "Messages", app: "messages", clip: clips["correction-001"], model: "english" },
    { id: "mail", title: "Mail", app: "mail", clip: clips["format-017"], model: "english" },
    { id: "notes", title: "Notes", app: "notes", clip: clips["format-013"], model: "english" },
    { id: "editor", title: "Code editor", app: "editor", clip: clips["dictionary-006"], model: "english" },
    { id: "french", title: "Français", app: "notes", clip: clips["multilingual-fr"], model: "multilingual" },
];
