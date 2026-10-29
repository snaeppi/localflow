<script lang="ts">
    // The menu bar: the frontmost app's menus (drawn only) and Localflow's menu bar item, whose menu works
    // (LocalflowApp.swift `StatusItem`).
    import BatteryFull from "@lucide/svelte/icons/battery-full";
    import Search from "@lucide/svelte/icons/search";
    import Wifi from "@lucide/svelte/icons/wifi";
    import Menu, { type MenuItem } from "./Menu.svelte";
    import { markPath, markViewBox } from "./mark-path";
    import { useStage } from "./stage";
    import { dictation } from "../demo/dictation.svelte";
    import { setCleanup } from "../cleanup";
    import { microphones, navigation, settings } from "../settings.svelte";

    let { app, height }: { app: string; height: number } = $props();
    const stage = useStage();
    let item = $state<HTMLElement>();
    let menu = $state<{ x: number; y: number } | null>(null);

    const ready = $derived(settings.models[settings.speechModel].kind === "installed");
    const glyph = $derived(dictation.phase === "recording" ? "recording" : ready ? "idle" : "attention");

    const items = $derived.by((): MenuItem[] => {
        const list: MenuItem[] = [];
        if (!ready) list.push({ label: "No speech model: download one in Settings", disabled: true }, { separator: true });
        list.push(
            {
                label: "Toggle Recording",
                action: () => {
                    dictation.stopAutoplay();
                    dictation.toggle();
                },
            },
            {
                label: "Copy Last Transcript",
                disabled: !dictation.lastTranscript,
                action: () => navigator.clipboard?.writeText(dictation.lastTranscript ?? ""),
            },
            { label: "Settings…", shortcut: "⌘,", action: openSettings },
            { separator: true },
            {
                label: settings.microphoneName,
                submenu: [
                    { label: "Automatic", checked: settings.microphone === null, action: () => (settings.microphone = null) },
                    { separator: true },
                    ...microphones.map((m) => ({
                        label: m.name,
                        checked: settings.microphone === m.id,
                        action: () => (settings.microphone = m.id),
                    })),
                ],
            },
            {
                label: settings.cleansUp ? "Cleanup On" : "Cleanup Off",
                submenu:
                    settings.speechModel === "english"
                        ? [
                              { label: "On", checked: settings.cleanup, action: () => setCleanup(true) },
                              { label: "Off", checked: !settings.cleanup, action: () => setCleanup(false) },
                          ]
                        : [{ label: "Needs the English speech model", disabled: true }],
            },
            { separator: true },
            { label: "Version 0.1", disabled: true },
            { label: "Quit", shortcut: "⌘Q", action: () => {} },
        );
        return list;
    });

    function openSettings() {
        dictation.stopAutoplay();
        navigation.mode = "settings";
    }

    function showMenu() {
        if (!item) return;
        const rect = stage.toStage(item.getBoundingClientRect());
        menu = { x: rect.x - 4, y: height + 1 };
    }

    function click(event: MouseEvent) {
        if (settings.recordOnMenuBarClick && event.button === 0 && !event.ctrlKey) {
            dictation.stopAutoplay();
            dictation.toggle();
        } else {
            showMenu();
        }
    }
</script>

<div class="menubar" style:height="{height}px">
    <span class="app">{app}</span>
    {#each app === "Localflow" ? ["Edit", "Window", "Help"] : ["File", "Edit", "View", "Window", "Help"] as name (name)}
        <span class="menu-title">{name}</span>
    {/each}
    <span class="fill"></span>
    <button
        bind:this={item}
        class="status-item"
        class:active={!!menu}
        aria-label="Localflow"
        onclick={click}
        oncontextmenu={(e) => {
            e.preventDefault();
            showMenu();
        }}
    >
        <svg width="22" height="18" viewBox="0 0 22 18" aria-hidden="true">
            {#if glyph === "recording"}
                <defs>
                    <mask id="knockout">
                        <rect width="22" height="18" rx="4.5" fill="#fff" />
                        <svg x="3" y="4.63" width="16" height="9.15" viewBox={markViewBox}><path d={markPath} fill="#000" /></svg>
                    </mask>
                </defs>
                <rect width="22" height="18" rx="4.5" fill="currentColor" mask="url(#knockout)" />
            {:else}
                <svg
                    x="0"
                    y="2.62"
                    width="22"
                    height="12.58"
                    viewBox={markViewBox}
                    opacity={glyph === "attention" ? 0.45 : 1}><path d={markPath} fill="currentColor" /></svg
                >
                {#if glyph === "attention"}<line x1="3" y1="1.5" x2="19" y2="16.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" />{/if}
            {/if}
        </svg>
    </button>
    <span class="icon"><Wifi size={15} strokeWidth={2.2} /></span>
    <span class="icon"><BatteryFull size={19} strokeWidth={1.6} /></span>
    <span class="icon"><Search size={13} strokeWidth={2.4} /></span>
    <span class="clock">Mon 26 Oct 9:41</span>
</div>

{#if menu}
    <Menu {items} x={menu.x} y={menu.y} onclose={() => (menu = null)} />
{/if}

<style>
    .menubar {
        position: absolute;
        z-index: 30;
        top: 0;
        left: 0;
        right: 0;
        display: flex;
        align-items: center;
        gap: 2px;
        padding: 0 10px 0 16px;
        background: var(--menubar);
        -webkit-backdrop-filter: blur(20px) saturate(1.4);
        backdrop-filter: blur(20px) saturate(1.4);
        color: var(--menubar-text);
        font-size: 13px;
    }

    .app {
        font-weight: 700;
        padding: 0 9px 0 4px;
    }

    .menu-title {
        padding: 0 9px;
    }

    .fill {
        flex: 1;
    }

    .status-item,
    .icon {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        height: 22px;
        padding: 0 7px;
        border-radius: 6px;
    }

    .status-item:hover,
    .status-item.active {
        background: rgb(127 127 127 / 0.22) !important;
    }

    .clock {
        padding: 0 8px 0 6px;
        white-space: nowrap;
    }
</style>
