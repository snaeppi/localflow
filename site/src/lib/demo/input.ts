// The dictation shortcuts on the page, as the app's event tap handles them (HotkeyMonitor.swift): a
// right-hand modifier on its own or a key combination; another key while a modifier shortcut is held is a
// shortcut (Right ⌘ + C), which goes through and discards the dictation; the cancel key cancels.
import { combination } from "../mac/ShortcutField.svelte";
import { navigation, sameShortcut, settings, type Shortcut } from "../settings.svelte";
import { dictation, type Source } from "./dictation.svelte";

const isModifierShortcut = (s: Shortcut | null): s is Shortcut => !!s && s.modifiers.length === 0 && s.code.endsWith("Right");

const modifierCodes: Record<Shortcut["modifiers"][number], string[]> = {
    "⌘": ["MetaLeft", "MetaRight"],
    "⌥": ["AltLeft", "AltRight"],
    "⌃": ["ControlLeft", "ControlRight"],
    "⇧": ["ShiftLeft", "ShiftRight"],
};

/** Which source a shortcut is: the shared key, push to talk alone, or toggle alone. */
function source(shortcut: Shortcut | null): Source | null {
    if (!shortcut) return null;
    const ptt = sameShortcut(shortcut, settings.pushToTalk);
    const toggle = sameShortcut(shortcut, settings.toggleShortcut);
    if (ptt && toggle) return "combined";
    if (ptt) return "pushToTalk";
    if (toggle) return "toggle";
    return null;
}

/** The on-screen key acts as the dictation shortcut. */
export function shortcutSource(): Source {
    return source(settings.pushToTalk) ?? source(settings.toggleShortcut) ?? "combined";
}

/** A key combination pressed; finishing with Shift held on top counts too ("Hold Shift to send"). */
function matches(shortcut: Shortcut, pressed: Shortcut) {
    if (sameShortcut(shortcut, pressed)) return true;
    const withShift = { ...shortcut, modifiers: [...shortcut.modifiers, "⇧" as const] };
    const order = ["⌃", "⌥", "⇧", "⌘"];
    withShift.modifiers.sort((a, b) => order.indexOf(a) - order.indexOf(b));
    return dictation.phase === "recording" && !shortcut.modifiers.includes("⇧") && sameShortcut(withShift, pressed);
}

export function attachShortcuts(): () => void {
    /** A modifier shortcut that's down; a toggle on a modifier acts when it's released without another key. */
    let heldModifier: { code: string; source: Source } | null = null;
    let heldKey: { shortcut: Shortcut; code: string; source: Source } | null = null;
    const shifts = new Set<string>();

    // Shift held as a dictation ends: the left one, or the right one when it isn't itself the shortcut.
    const updateShift = () => {
        const rightIsShortcut = [settings.pushToTalk, settings.toggleShortcut].some((s) => s?.code === "ShiftRight" && isModifierShortcut(s));
        dictation.setShift(shifts.has("ShiftLeft") || (shifts.has("ShiftRight") && !rightIsShortcut));
    };

    const keydown = (event: KeyboardEvent) => {
        if (event.code.startsWith("Shift")) shifts.add(event.code);
        updateShift();
        if (navigation.recordingShortcut || event.repeat) return;
        for (const shortcut of [settings.pushToTalk, settings.toggleShortcut]) {
            if (isModifierShortcut(shortcut) && event.code === shortcut.code) {
                const s = source(shortcut)!;
                heldModifier = { code: event.code, source: s };
                dictation.stopAutoplay();
                if (s !== "toggle") dictation.down(s);
                return;
            }
        }
        const pressed = combination(event);
        if (!pressed) return;
        for (const shortcut of [settings.pushToTalk, settings.toggleShortcut]) {
            if (shortcut && !isModifierShortcut(shortcut) && matches(shortcut, pressed)) {
                event.preventDefault();
                const s = source(shortcut)!;
                heldKey = { shortcut, code: event.code, source: s };
                dictation.stopAutoplay();
                dictation.down(s);
                return;
            }
        }
        if (heldModifier?.source === "toggle") {
            heldModifier = null; // Right ⌥ + C with Right ⌥ as the toggle: just the shortcut.
            return;
        }
        if (dictation.phase !== "recording") return;
        if (sameShortcut(settings.cancelShortcut, pressed)) {
            event.preventDefault();
            dictation.stopAutoplay();
            dictation.cancel();
        } else if (heldModifier) {
            // A shortcut such as Right ⌘ + C: the key goes to the page, the dictation is dropped.
            dictation.cancel();
            heldModifier = null;
        }
    };

    const keyup = (event: KeyboardEvent) => {
        shifts.delete(event.code);
        updateShift();
        if (heldModifier && event.code === heldModifier.code) {
            if (heldModifier.source === "toggle") dictation.down("toggle");
            else dictation.up(heldModifier.source);
            heldModifier = null;
        } else if (
            heldKey &&
            // Browsers on the Mac send no key-up for a key released while ⌘ is down: the modifier's counts.
            (event.code === heldKey.code || heldKey.shortcut.modifiers.some((m) => modifierCodes[m].includes(event.code)))
        ) {
            dictation.up(heldKey.source);
            heldKey = null;
        }
    };

    // The page lost focus with the shortcut down: the other key (Right ⌘ + Tab, + Space) went elsewhere,
    // a chord, so the dictation is dropped.
    const blur = () => {
        if ((heldModifier && heldModifier.source !== "toggle") || heldKey) dictation.cancel();
        heldModifier = heldKey = null;
        shifts.clear();
        updateShift();
    };

    window.addEventListener("keydown", keydown);
    window.addEventListener("keyup", keyup);
    window.addEventListener("blur", blur);
    return () => {
        window.removeEventListener("keydown", keydown);
        window.removeEventListener("keyup", keyup);
        window.removeEventListener("blur", blur);
    };
}

/** The mouse shortcut, over the replica's screen: hold to talk, click for hands-free. */
export function mouseShortcut(node: HTMLElement) {
    const button = (event: PointerEvent | MouseEvent) => (event.button === 1 ? 2 : event.button);
    const down = (event: PointerEvent) => {
        if (navigation.recordingShortcut || settings.mouseShortcut === null || button(event) !== settings.mouseShortcut) return;
        event.preventDefault();
        // So the release arrives here even if the pointer has left the screen.
        node.setPointerCapture(event.pointerId);
        dictation.stopAutoplay();
        dictation.down("combined");
    };
    const up = (event: PointerEvent) => {
        if (settings.mouseShortcut === null || button(event) !== settings.mouseShortcut) return;
        event.preventDefault();
        dictation.up("combined");
    };
    // Side buttons would go back and forward in the browser's history.
    const swallow = (event: MouseEvent) => {
        if (settings.mouseShortcut !== null && button(event) === settings.mouseShortcut) event.preventDefault();
    };
    node.addEventListener("pointerdown", down);
    node.addEventListener("pointerup", up);
    node.addEventListener("mouseup", swallow);
    node.addEventListener("auxclick", swallow);
    return {
        destroy() {
            node.removeEventListener("pointerdown", down);
            node.removeEventListener("pointerup", up);
            node.removeEventListener("mouseup", swallow);
            node.removeEventListener("auxclick", swallow);
        },
    };
}
