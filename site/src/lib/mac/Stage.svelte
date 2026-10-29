<script lang="ts">
    // A Mac screen at point size, scaled to the page: wallpaper, menu bar, the Settings window or the app a
    // scene dictates into, the recording window, and a top layer for menus and popovers.
    import { MediaQuery } from "svelte/reactivity";
    import AppWindow from "./AppWindow.svelte";
    import Caption from "./Caption.svelte";
    import MenuBar from "./MenuBar.svelte";
    import RecordingWindow from "./RecordingWindow.svelte";
    import SettingsWindow from "./SettingsWindow.svelte";
    import { setStage } from "./stage";
    import { dictation } from "../demo/dictation.svelte";
    import { navigation, settings } from "../settings.svelte";

    const width = 1100;
    const height = 700;
    const menuBarHeight = 26;

    let available = $state(width);
    let screen = $state<HTMLElement>();
    let layer = $state<HTMLElement>();
    const scale = $derived(Math.min(1, available / width));
    const prefersDark = new MediaQuery("(prefers-color-scheme: dark)");
    const appearance = $derived(settings.theme === "auto" ? (prefersDark.current ? "dark" : "light") : settings.theme);
    const scene = $derived(dictation.scene);

    setStage({
        layer: () => layer,
        size: () => ({ width, height }),
        toStage(rect) {
            const s = screen!.getBoundingClientRect();
            return {
                x: (rect.left - s.left) / scale,
                y: (rect.top - s.top) / scale,
                width: rect.width / scale,
                height: rect.height / scale,
            };
        },
    });
</script>

<div class="frame" bind:clientWidth={available} style:height="{height * scale}px">
    <div
        bind:this={screen}
        class="screen mac {appearance}"
        style:width="{width}px"
        style:height="{height}px"
        style:transform="scale({scale})"
    >
        <div class="wallpaper"></div>
        <MenuBar app={navigation.mode === "settings" ? "Localflow" : scene.app === "editor" ? "Editor" : scene.title === "Français" ? "Notes" : scene.title} height={menuBarHeight} />

        {#if navigation.mode === "settings"}
            <div class="slot settings-slot"><SettingsWindow onclose={() => (navigation.mode = "dictation")} /></div>
        {:else}
            {#key scene.id}
                <div class="slot app-slot"><AppWindow app={scene.app} sceneId={scene.id} french={scene.model === "multilingual"} /></div>
            {/key}
            <Caption />
        {/if}

        <RecordingWindow {menuBarHeight} />
        <div bind:this={layer} class="layer"></div>
    </div>
</div>

<style>
    .frame {
        position: relative;
        width: 100%;
        max-width: 1100px;
        margin: 0 auto;
    }

    .screen {
        position: absolute;
        top: 0;
        left: 0;
        transform-origin: 0 0;
        overflow: hidden;
        border-radius: 14px;
        box-shadow:
            0 0 0 1px rgb(0 0 0 / 0.08),
            0 30px 80px rgb(0 0 0 / 0.18);
        isolation: isolate;
    }

    .wallpaper {
        position: absolute;
        inset: 0;
        background:
            radial-gradient(120% 90% at 15% 110%, var(--wall-1), transparent 60%),
            radial-gradient(90% 80% at 90% 0%, var(--wall-2), transparent 60%),
            radial-gradient(70% 70% at 70% 80%, var(--wall-3), transparent 70%),
            var(--wall-base);
    }

    .slot {
        position: absolute;
        left: 50%;
        transform: translateX(-50%);
    }

    .settings-slot {
        top: 92px;
    }

    .app-slot {
        top: 110px;
        animation: open 0.3s ease-out;
    }

    @keyframes open {
        from {
            opacity: 0;
            transform: translateX(-50%) scale(0.97);
        }
    }

    .layer {
        position: absolute;
        inset: 0;
        z-index: 50;
        pointer-events: none;
    }

    .layer > :global(*) {
        pointer-events: auto;
    }
</style>
