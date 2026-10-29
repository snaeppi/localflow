<script lang="ts" generics="T extends string | number">
    // A pop-up button (SwiftUI's Picker in a form): its menu opens over it with the current choice checked.
    import type { Component } from "svelte";
    import ChevronsUpDown from "@lucide/svelte/icons/chevrons-up-down";
    import Menu from "./Menu.svelte";
    import { useStage } from "./stage";

    let {
        value,
        options,
        label,
        onchange,
    }: {
        value: T;
        options: { value: T; title: string; icon?: Component<{ size?: number; strokeWidth?: number }> }[];
        label: string;
        onchange: (value: T) => void;
    } = $props();

    const stage = useStage();
    let button = $state<HTMLElement>();
    let menu = $state<{ x: number; y: number; width: number } | null>(null);
    const current = $derived(options.find((o) => o.value === value) ?? options[0]);

    function show() {
        if (!button) return;
        const rect = stage.toStage(button.getBoundingClientRect());
        const index = options.findIndex((o) => o.value === value);
        // The checked item over the button, as macOS opens pop-up menus.
        menu = { x: rect.x - 22, y: rect.y - 3 - Math.max(0, index) * 24, width: rect.width + 30 };
    }
</script>

<button bind:this={button} class="popup" aria-label={label} onclick={show}>
    {#if current.icon}<current.icon size={13} strokeWidth={1.8} />{/if}
    <span>{current.title}</span>
    <ChevronsUpDown size={11} strokeWidth={2.2} />
</button>

{#if menu}
    <Menu
        x={menu.x}
        y={menu.y}
        width={menu.width}
        onclose={() => (menu = null)}
        items={options.map((o) => ({ label: o.title, icon: o.icon, checked: o.value === value, action: () => onchange(o.value) }))}
    />
{/if}

<style>
    .popup {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        height: 24px;
        padding: 0 8px 0 10px;
        border-radius: 8px;
        background: var(--popup);
        white-space: nowrap;
    }

    .popup span {
        margin-right: 8px;
    }
</style>
