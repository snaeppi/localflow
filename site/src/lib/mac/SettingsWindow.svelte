<script lang="ts">
    // The Settings window (SettingsView.swift): a sidebar of pages on a translucent window, each page with
    // its title level with the traffic lights. A click on the sidebar's edge folds it to its icons.
    import BookA from "@lucide/svelte/icons/book-a";
    import BookOpen from "@lucide/svelte/icons/book-open";
    import ChevronLeft from "@lucide/svelte/icons/chevron-left";
    import ChevronRight from "@lucide/svelte/icons/chevron-right";
    import Eraser from "@lucide/svelte/icons/eraser";
    import Gear from "@lucide/svelte/icons/settings";
    import Volume2 from "@lucide/svelte/icons/volume-2";
    import Advanced from "./pages/Advanced.svelte";
    import Cleanup from "./pages/Cleanup.svelte";
    import General from "./pages/General.svelte";
    import Models from "./pages/Models.svelte";
    import Sound from "./pages/Sound.svelte";
    import Vocabulary from "./pages/Vocabulary.svelte";
    import { navigation, settings } from "../settings.svelte";

    let { onclose }: { onclose: () => void } = $props();

    const pages = [
        { id: "general", title: "General", icon: Gear, tint: "gray" },
        { id: "sound", title: "Sound", icon: Volume2, tint: "gray" },
        { id: "models", title: "Models", icon: BookOpen, tint: "gray" },
        { id: "vocabulary", title: "Vocabulary", icon: BookA, tint: "blue" },
        { id: "cleanup", title: "Cleanup", icon: Eraser, tint: "purple" },
    ] as const;

    const ready = $derived(settings.models[settings.speechModel].kind === "installed");
    const status = $derived(
        ready
            ? { text: settings.dictationHint, color: "#34c759" }
            : settings.models[settings.speechModel].kind === "downloading"
              ? { text: "Loading speech model…", color: "#ff9f0a" }
              : { text: "No speech model", color: "#ff453a" },
    );
</script>

<div class="window" class:folded={navigation.sidebarFolded}>
    <div class="lights">
        <button class="light close" aria-label="Close" onclick={onclose}></button>
        {#if !navigation.sidebarFolded}<button class="light minimize" aria-label="Minimize" onclick={onclose}></button>{/if}
    </div>
    <nav class="sidebar">
        {#each pages as page (page.id)}
            {@const selected = navigation.page === page.id}
            <button
                class="row"
                class:selected
                title={navigation.sidebarFolded ? page.title : undefined}
                aria-current={selected}
                onclick={() => {
                    navigation.page = page.id;
                    navigation.advanced = false;
                }}
            >
                <span class="icon {page.tint}"><page.icon size={11} strokeWidth={2.4} /></span>
                <span class="label">{page.title}</span>
            </button>
        {/each}
        <span class="fill"></span>
        <div class="status" title={status.text}>
            <span class="dot" style:background={status.color}></span>
            <span class="status-text">{status.text}</span>
        </div>
    </nav>
    <button
        class="edge"
        aria-label={navigation.sidebarFolded ? "Show sidebar" : "Hide sidebar"}
        onclick={() => (navigation.sidebarFolded = !navigation.sidebarFolded)}
    >
        <span class="edge-button">
            {#if navigation.sidebarFolded}<ChevronRight size={12} strokeWidth={2.6} />{:else}<ChevronLeft size={12} strokeWidth={2.6} />{/if}
        </span>
    </button>
    <main class="pages">
        {#if navigation.page === "general" && navigation.advanced}
            <Advanced />
        {:else if navigation.page === "general"}
            <General />
        {:else if navigation.page === "sound"}
            <Sound />
        {:else if navigation.page === "models"}
            <Models />
        {:else if navigation.page === "vocabulary"}
            <Vocabulary />
        {:else}
            <Cleanup />
        {/if}
    </main>
</div>

<style>
    .window {
        --sidebar-width: 185px;
        position: relative;
        display: flex;
        width: 780px;
        height: 560px;
        border-radius: 16px;
        overflow: hidden;
        background: var(--window-sidebar);
        -webkit-backdrop-filter: blur(50px) saturate(1.5);
        backdrop-filter: blur(50px) saturate(1.5);
        box-shadow:
            0 0 0 0.5px var(--window-edge),
            inset 0 0 0 0.5px rgb(255 255 255 / 0.12),
            0 22px 70px rgb(0 0 0 / 0.35),
            0 4px 14px rgb(0 0 0 / 0.12);
    }

    .folded {
        --sidebar-width: 60px;
    }

    .lights {
        position: absolute;
        top: 13px;
        left: 12px;
        z-index: 3;
        display: flex;
        gap: 9px;
    }

    .light {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        box-shadow: inset 0 0 0 0.5px rgb(0 0 0 / 0.18);
    }

    .close {
        background: #ff5f57 !important;
    }

    .minimize {
        background: #febc2e !important;
    }

    .sidebar {
        position: relative;
        display: flex;
        flex-direction: column;
        flex-shrink: 0;
        width: var(--sidebar-width);
        padding: 52px 12px 12px;
        overflow: hidden;
        box-shadow: inset -1px 0 0 var(--fill);
        transition: width 0.27s cubic-bezier(0.25, 1, 0.5, 1);
    }

    .row {
        position: relative;
        display: flex;
        align-items: center;
        height: 35px;
        padding: 0 8px;
        border-radius: 10px;
        white-space: nowrap;
        text-align: left;
    }

    .row:hover:not(.selected) {
        background: var(--fill) !important;
    }

    .row.selected {
        background: var(--glass) !important;
        box-shadow:
            inset 0 0 0 0.5px var(--glass-edge),
            inset 0 1px 0 var(--card-shine),
            0 1px 2px rgb(0 0 0 / 0.06);
    }

    .icon {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
        width: 19px;
        height: 19px;
        border-radius: 5px;
        color: #fff;
    }

    .icon.gray {
        background: linear-gradient(#a1a1a6, #85858a);
    }

    .icon.blue {
        background: linear-gradient(#4aa0ff, #1f7cf5);
    }

    .icon.purple {
        background: linear-gradient(#e070f0, #a646dc);
    }

    .label {
        margin-left: 7px;
        transition: opacity 0.2s ease-in;
    }

    .folded .label {
        opacity: 0;
        transition: opacity 0.08s ease-out;
    }

    .fill {
        flex: 1;
    }

    .status {
        display: flex;
        align-items: center;
        gap: 7px;
        min-height: 36px;
        padding-left: 10px;
        border-radius: 18px;
        background: var(--glass);
        box-shadow:
            inset 0 0 0 0.5px var(--glass-edge),
            inset 0 1px 0 var(--card-shine);
        white-space: nowrap;
        transition: padding 0.27s;
    }

    .folded .status {
        padding-left: 15px;
    }

    .dot {
        flex-shrink: 0;
        width: 6px;
        height: 6px;
        border-radius: 50%;
    }

    .status-text {
        font-size: 11px;
        color: var(--label-2);
        transition: opacity 0.2s;
    }

    .folded .status-text {
        opacity: 0;
    }

    .edge {
        position: absolute;
        z-index: 2;
        top: 0;
        bottom: 0;
        left: calc(var(--sidebar-width) - 8px);
        width: 16px;
        display: flex;
        align-items: center;
        justify-content: center;
        cursor: pointer !important;
        transition: left 0.27s cubic-bezier(0.25, 1, 0.5, 1);
    }

    .edge-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 25px;
        height: 25px;
        flex-shrink: 0;
        border-radius: 50%;
        background: var(--card);
        box-shadow:
            0 0 0 0.5px var(--glass-edge),
            0 1px 4px rgb(0 0 0 / 0.15);
        color: var(--label-2);
        opacity: 0;
        transition: opacity 0.15s ease-out;
        pointer-events: none;
    }

    .edge:hover .edge-button {
        opacity: 1;
    }

    .pages {
        flex: 1;
        min-width: 0;
        background: var(--page-tint);
    }
</style>
