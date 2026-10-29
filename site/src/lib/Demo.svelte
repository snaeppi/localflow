<script lang="ts">
    // The replica and its controls: the Settings window, or a dictation into one of the scenes.
    import Pause from "@lucide/svelte/icons/pause";
    import Play from "@lucide/svelte/icons/play";
    import Volume2 from "@lucide/svelte/icons/volume-2";
    import VolumeX from "@lucide/svelte/icons/volume-x";
    import Stage from "./mac/Stage.svelte";
    import { scenes } from "./demo/clips";
    import { dictation } from "./demo/dictation.svelte";
    import { attachShortcuts, mouseShortcut, shortcutSource } from "./demo/input";
    import { setCleanup } from "./cleanup";
    import { navigation, sameShortcut, settings, title } from "./settings.svelte";

    $effect(() => attachShortcuts());

    const shortcut = $derived(settings.pushToTalk ?? settings.toggleShortcut);
    const keyLabel = $derived(shortcut ? title(shortcut) : "Dictate");
    const hint = $derived.by(() => {
        if (dictation.phase === "recording" && dictation.handsFree) return `Hands-free: press ${keyLabel} again to finish`;
        if (dictation.phase === "recording") return "Release to paste";
        if (!settings.pushToTalk) return `Press ${keyLabel} to start and again to finish`;
        if (sameShortcut(settings.toggleShortcut, settings.pushToTalk)) return `Hold ${keyLabel} to talk, or tap it for hands-free`;
        return `Hold ${keyLabel} to talk`;
    });
    let source: ReturnType<typeof shortcutSource> = "combined";

    function keyDown(event: PointerEvent) {
        if (event.button !== 0) return;
        (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
        dictation.stopAutoplay();
        dictation.keyDown = true;
        source = shortcutSource();
        dictation.down(source);
    }

    function keyUp() {
        if (!dictation.keyDown) return;
        dictation.keyDown = false;
        dictation.up(source);
    }
</script>

<div class="demo">
    <div class="tabs">
        <button
            aria-pressed={navigation.mode === "dictation"}
            onclick={() => {
                dictation.stopAutoplay();
                navigation.mode = "dictation";
            }}>Dictation</button
        >
        <button
            aria-pressed={navigation.mode === "settings"}
            onclick={() => {
                dictation.stopAutoplay();
                navigation.mode = "settings";
            }}>Settings window</button
        >
    </div>

    <div use:mouseShortcut>
        <Stage />
    </div>

    {#if navigation.mode === "dictation"}
        <div class="controls">
            <div class="scenes">
                {#each scenes as scene, i (scene.id)}
                    <button
                        aria-pressed={dictation.sceneIndex === i}
                        onclick={() => {
                            dictation.stopAutoplay();
                            dictation.selectScene(i);
                        }}>{scene.title}</button
                    >
                {/each}
            </div>
            <div class="row">
                <button
                    class="key"
                    class:down={dictation.keyDown || dictation.phase === "recording"}
                    onpointerdown={keyDown}
                    onpointerup={keyUp}
                    onpointercancel={keyUp}
                    onclick={(e) => {
                        // From the keyboard (Space, Return): no press to hold, so it toggles.
                        if (e.detail === 0) {
                            dictation.stopAutoplay();
                            dictation.toggle();
                        }
                    }}
                    oncontextmenu={(e) => e.preventDefault()}>{keyLabel}</button
                >
                <div class="side">
                    <p class="hint" aria-live="polite">{hint}</p>
                    <div class="toggles">
                        <button
                            class="pill-button"
                            onclick={() => {
                                if (dictation.autoplay) return dictation.stopAutoplay();
                                dictation.stopAutoplay();
                                dictation.playAll();
                            }}
                        >
                            {#if dictation.autoplay}<Pause size={14} /> Stop{:else}<Play size={14} /> Play all{/if}
                        </button>
                        <label class="check" class:disabled={dictation.scene.model !== "english"}>
                            <input
                                type="checkbox"
                                checked={settings.cleanup}
                                disabled={dictation.scene.model !== "english"}
                                onchange={(e) => setCleanup(e.currentTarget.checked)}
                            />
                            Clean up transcripts
                        </label>
                        <button class="pill-button" aria-pressed={dictation.sound} onclick={() => dictation.setSound(!dictation.sound)}>
                            {#if dictation.sound}<Volume2 size={14} /> Sound on{:else}<VolumeX size={14} /> Sound off{/if}
                        </button>
                    </div>
                </div>
            </div>
            <p class="note">
                {#if dictation.scene.model === "multilingual"}
                    French uses the multilingual model, which has no cleanup.
                {/if}
                The voices are synthesized (Kokoro TTS); the transcripts and cleanups are Localflow's own output for
                these recordings (if you release early, the transcript stops where the recording did), and the
                paste comes as long after the release as in the app (~60 ms, ~80 ms with cleanup).
            </p>
        </div>
    {:else}
        <p class="settings-note">
            A copy of the Settings window: the pages, switches, shortcut fields, menus and (i) explanations work, and
            the dictation follows what you set here. The menu bar icon has Localflow's menu.
        </p>
    {/if}
</div>

<style>
    .demo {
        display: flex;
        flex-direction: column;
        gap: 18px;
    }

    .tabs,
    .scenes {
        display: flex;
        justify-content: center;
        gap: 4px;
        flex-wrap: wrap;
    }

    .tabs button,
    .scenes button {
        border: 0;
        border-radius: 999px;
        padding: 6px 14px;
        background: transparent;
        color: var(--text-2);
        font-size: 14px;
        cursor: pointer;
    }

    .tabs button[aria-pressed="true"],
    .scenes button[aria-pressed="true"] {
        background: var(--text);
        color: var(--bg);
    }

    .tabs button:hover:not([aria-pressed="true"]),
    .scenes button:hover:not([aria-pressed="true"]) {
        background: var(--line);
    }

    .controls {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 18px;
    }

    .row {
        display: flex;
        align-items: center;
        gap: 22px;
        flex-wrap: wrap;
        justify-content: center;
    }

    .key {
        min-width: 132px;
        height: 58px;
        padding: 0 22px;
        border: 0;
        border-radius: 12px;
        background: linear-gradient(#2c2c2e, #1c1c1e);
        color: #fff;
        font-family: var(--mono);
        font-size: 17px;
        box-shadow:
            0 0 0 1px rgb(0 0 0 / 0.6),
            0 4px 0 #0c0c0d,
            0 8px 18px rgb(0 0 0 / 0.25);
        transform: translateY(-2px);
        transition:
            transform 0.06s,
            box-shadow 0.06s;
        cursor: pointer;
        touch-action: none;
        user-select: none;
        -webkit-user-select: none;
    }

    .key.down {
        transform: translateY(2px);
        box-shadow:
            0 0 0 1px rgb(0 0 0 / 0.6),
            0 0 0 #0c0c0d,
            0 3px 8px rgb(0 0 0 / 0.25);
    }

    .side {
        display: flex;
        flex-direction: column;
        gap: 10px;
    }

    .hint {
        margin: 0;
        font-size: 15px;
        min-height: 1.5em;
    }

    .toggles {
        display: flex;
        gap: 10px;
        align-items: center;
        flex-wrap: wrap;
    }

    .pill-button {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        border: 1px solid var(--line);
        border-radius: 999px;
        padding: 4px 12px;
        background: var(--surface);
        font-size: 13px;
        cursor: pointer;
    }

    .check {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        font-size: 13px;
        cursor: pointer;
    }

    .check.disabled {
        color: var(--text-3);
    }

    .note,
    .settings-note {
        max-width: 640px;
        margin: 0 auto;
        color: var(--text-3);
        font-size: 13px;
        text-align: center;
    }
</style>
