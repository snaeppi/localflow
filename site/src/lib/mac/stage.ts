// The replica's screen is drawn at macOS point size and scaled to fit the page; popovers and menus go to
// a layer above its windows (as they float over everything on a Mac), positioned in screen points.
import { getContext, setContext } from "svelte";

export interface StageContext {
    /** The element popovers and menus are moved into. */
    layer(): HTMLElement | undefined;
    /** A rectangle on the page in the screen's points. */
    toStage(rect: DOMRect): { x: number; y: number; width: number; height: number };
    /** The screen's size in points. */
    size(): { width: number; height: number };
}

const key = Symbol("stage");
export const setStage = (context: StageContext) => setContext(key, context);
export const useStage = () => getContext<StageContext>(key);

/** Moves the node into `target` for as long as it exists. */
export function portal(node: HTMLElement, target: HTMLElement | undefined) {
    target?.appendChild(node);
    return {
        destroy() {
            node.remove();
        },
    };
}

/**
 * Calls `close` on a pointer press outside `nodes`, on Esc, or when something scrolls (the popover would
 * stay behind). With `swallow`, as for menus, the press that closes it goes no further.
 */
export function dismissOnOutside(nodes: () => (Element | undefined | null)[], close: () => void, swallow = false) {
    const stop = (event: Event) => {
        event.preventDefault();
        event.stopPropagation();
    };
    const down = (event: PointerEvent) => {
        if (nodes().some((n) => n?.contains(event.target as Node))) return;
        close();
        if (!swallow) return;
        stop(event);
        window.addEventListener("click", stop, { capture: true, once: true });
        setTimeout(() => window.removeEventListener("click", stop, { capture: true }), 500);
    };
    const key = (event: KeyboardEvent) => {
        if (event.key === "Escape") {
            event.stopPropagation();
            close();
        }
    };
    const scroll = (event: Event) => {
        if (!nodes().some((n) => n?.contains(event.target as Node))) close();
    };
    // After the click that opened it.
    const timer = setTimeout(() => {
        window.addEventListener("pointerdown", down, true);
        window.addEventListener("keydown", key, true);
        window.addEventListener("scroll", scroll, true);
    });
    return () => {
        clearTimeout(timer);
        window.removeEventListener("pointerdown", down, true);
        window.removeEventListener("keydown", key, true);
        window.removeEventListener("scroll", scroll, true);
    };
}
