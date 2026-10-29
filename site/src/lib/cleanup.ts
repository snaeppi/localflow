// Turning cleanup on downloads its model first, as in the app (here a few seconds, then ~1 s converting).
import { navigation, settings } from "./settings.svelte";

let timer: ReturnType<typeof setInterval> | undefined;

export function setCleanup(on: boolean) {
    settings.cleanup = on;
    if (!on) {
        // Off cancels a download.
        clearInterval(timer);
        if (settings.cleanupModel.kind !== "installed") settings.cleanupModel = { kind: "absent" };
        return;
    }
    if (settings.cleanupModel.kind !== "absent") return; // Installed, or already on its way.
    settings.cleanupModel = { kind: "downloading", fraction: 0 };
    timer = setInterval(() => {
        const state = settings.cleanupModel;
        if (state.kind !== "downloading") return clearInterval(timer);
        const fraction = Math.min(1, state.fraction + 0.015 + Math.random() * 0.025);
        if (fraction < 1) {
            settings.cleanupModel = { kind: "downloading", fraction };
            return;
        }
        clearInterval(timer);
        settings.cleanupModel = { kind: "preparing" };
        setTimeout(() => {
            if (settings.cleanupModel.kind === "preparing") settings.cleanupModel = { kind: "installed" };
        }, 1000);
    }, 80);
}

/**
 * The recording window's cleanup button (DictationController.toggleCleanup): switches cleanup, or opens
 * Settings › Cleanup when it can't run yet.
 */
export function toggleCleanup() {
    if (settings.speechModel === "english" && (settings.cleanup || settings.cleanupModel.kind === "installed")) {
        setCleanup(!settings.cleanup);
    } else {
        navigation.page = "cleanup";
        navigation.advanced = false;
        navigation.mode = "settings";
    }
}
