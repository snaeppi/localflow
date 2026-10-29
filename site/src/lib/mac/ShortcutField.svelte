<script lang="ts" module>
    import { rightModifiers, type Shortcut } from "../settings.svelte";

    const names: Record<string, string> = {
        Space: "Space", Enter: "↩", NumpadEnter: "⌤", Tab: "⇥", Backspace: "⌫", Delete: "⌦", Escape: "esc",
        ArrowLeft: "←", ArrowRight: "→", ArrowDown: "↓", ArrowUp: "↑", Home: "↖", End: "↘", PageUp: "⇞",
        PageDown: "⇟", Help: "Help",
    };
    const modifierCodes = new Set([
        "MetaLeft", "MetaRight", "AltLeft", "AltRight", "ControlLeft", "ControlRight", "ShiftLeft", "ShiftRight",
        "CapsLock", "Fn",
    ]);
    const isFunctionKey = (code: string) => /^F([1-9]|1[0-9]|20)$/.test(code);

    /** The key combination a key press makes, or null for a lone modifier. */
    export function combination(event: KeyboardEvent): Shortcut | null {
        if (modifierCodes.has(event.code)) return null;
        const key =
            names[event.code] ??
            (isFunctionKey(event.code) ? event.code : null) ??
            event.code.match(/^(?:Key|Digit)(.)$/)?.[1] ??
            (event.key.length === 1 ? event.key.toUpperCase() : event.code);
        const modifiers: Shortcut["modifiers"] = [];
        if (event.ctrlKey) modifiers.push("⌃");
        if (event.altKey) modifiers.push("⌥");
        if (event.shiftKey) modifiers.push("⇧");
        if (event.metaKey) modifiers.push("⌘");
        return { code: event.code, modifiers, key };
    }

    export const mouseTitle = (n: number) => (n === 2 ? "Middle button" : `Button ${n + 1}`);
</script>

<script lang="ts">
    // A shortcut field (Components.swift `ShortcutField`): keycaps, or "Record shortcut" when there's none. A
    // click listens for the next shortcut; Esc stops listening, ⌫ removes it (or brings back the default
    // where one is required), and the arrow brings back the default.
    import RotateCcw from "@lucide/svelte/icons/rotate-ccw";
    import KeyCap from "./KeyCap.svelte";
    import { navigation, sameShortcut, keycaps } from "../settings.svelte";

    type Props =
        | {
              kind: "key";
              value: Shortcut | null;
              defaultValue: Shortcut | null;
              others: (Shortcut | null)[];
              allowsNone?: boolean;
              allowsBareKeys?: boolean;
              modifierKeys?: boolean;
              onchange: (value: Shortcut | null) => void;
          }
        | { kind: "mouse"; value: number | null; defaultValue: null; onchange: (value: number | null) => void };

    let props: Props = $props();
    let recording = $state(false);
    let refused = $state(false);

    const isDefault = $derived(
        props.kind === "key" ? (props.value === null ? props.defaultValue === null : sameShortcut(props.value, props.defaultValue)) : props.value === props.defaultValue,
    );

    function start() {
        recording = true;
        navigation.recordingShortcut = true;
    }

    function stop() {
        recording = false;
        navigation.recordingShortcut = false;
    }

    function refuse() {
        // The app beeps; here the field shakes.
        refused = true;
        setTimeout(() => (refused = false), 300);
    }

    $effect(() => {
        if (!recording) return;
        let pendingModifier: string | null = null;
        const down = (event: KeyboardEvent) => {
            event.preventDefault();
            event.stopPropagation();
            const plain = !event.metaKey && !event.altKey && !event.ctrlKey && !event.shiftKey;
            if (event.code === "Escape" && plain) return stop();
            if (event.code === "Backspace" && plain) {
                if (props.kind === "key") props.onchange(props.allowsNone === false ? props.defaultValue : null);
                else props.onchange(null);
                return stop();
            }
            if (props.kind !== "key") return refuse();
            if (event.code in rightModifiers) {
                pendingModifier = event.code;
                return;
            }
            pendingModifier = null;
            const shortcut = combination(event);
            if (!shortcut) return;
            const allowed =
                props.allowsBareKeys || isFunctionKey(shortcut.code) || shortcut.modifiers.some((m) => m !== "⇧");
            if (!allowed || props.others.some((o) => sameShortcut(o, shortcut))) return refuse();
            props.onchange(shortcut);
            stop();
        };
        const up = (event: KeyboardEvent) => {
            event.preventDefault();
            if (props.kind !== "key" || props.modifierKeys === false) return;
            // A right-hand modifier pressed and released with nothing in between.
            if (event.code === pendingModifier) {
                const shortcut: Shortcut = { code: event.code, modifiers: [], key: rightModifiers[event.code] };
                if (props.others.some((o) => sameShortcut(o, shortcut))) return refuse();
                props.onchange(shortcut);
                stop();
            }
        };
        const mouse = (event: PointerEvent) => {
            if (props.kind !== "mouse") return;
            if (event.button === 0 || event.button === 2) return;
            event.preventDefault();
            props.onchange(event.button === 1 ? 2 : event.button);
            stop();
        };
        window.addEventListener("keydown", down, true);
        window.addEventListener("keyup", up, true);
        window.addEventListener("pointerdown", mouse, true);
        return () => {
            window.removeEventListener("keydown", down, true);
            window.removeEventListener("keyup", up, true);
            window.removeEventListener("pointerdown", mouse, true);
            navigation.recordingShortcut = false;
        };
    });
</script>

<div class="field">
    {#if !isDefault && !recording}
        <button
            class="reset"
            title={props.defaultValue === null ? "Remove shortcut" : "Reset to default"}
            aria-label={props.defaultValue === null ? "Remove shortcut" : "Reset to default"}
            onclick={() => (props.kind === "key" ? props.onchange(props.defaultValue) : props.onchange(null))}
        >
            <RotateCcw size={11} strokeWidth={2} />
        </button>
    {/if}
    <button class="value" class:refused onclick={() => (recording ? stop() : start())} onblur={stop}>
        {#if recording}
            <span class="listening">{props.kind === "mouse" ? "Press a mouse button…" : "Press shortcut…"}</span>
        {:else if props.value !== null}
            <span class="keys">
                {#if props.kind === "key"}
                    {#each keycaps(props.value) as key (key)}<KeyCap {key} />{/each}
                {:else}
                    <KeyCap key={mouseTitle(props.value)} />
                {/if}
            </span>
        {:else}
            <span class="none">Record shortcut</span>
        {/if}
    </button>
</div>

<style>
    .field {
        display: flex;
        align-items: center;
        gap: 10px;
    }

    .reset {
        display: inline-flex;
        color: var(--label-2);
    }

    .keys {
        display: flex;
        gap: 4px;
    }

    .listening {
        display: inline-flex;
        align-items: center;
        min-height: 26px;
        padding: 0 10px;
        border-radius: 7px;
        background: var(--fill);
        font-size: 12px;
        color: var(--label-2);
    }

    .none {
        font-size: 12px;
        color: var(--label-3);
    }

    .refused {
        animation: shake 0.3s;
    }

    @keyframes shake {
        25% {
            transform: translateX(-3px);
        }
        75% {
            transform: translateX(3px);
        }
    }
</style>
