<script lang="ts" module>
    import type { Component } from "svelte";

    export type MenuItem =
        | { separator: true }
        | {
              separator?: false;
              label: string;
              icon?: Component<{ size?: number; strokeWidth?: number }>;
              checked?: boolean;
              disabled?: boolean;
              shortcut?: string;
              submenu?: MenuItem[];
              action?: () => void;
          };
</script>

<script lang="ts">
    // A macOS menu: the menu bar's menus, pop-up buttons and context menus. Submenus open on hover.
    import Check from "@lucide/svelte/icons/check";
    import ChevronRight from "@lucide/svelte/icons/chevron-right";
    import Self from "./Menu.svelte";
    import { dismissOnOutside, portal, useStage } from "./stage";

    let {
        items,
        x,
        y,
        width,
        leftEdge,
        onclose,
        nested = false,
    }: {
        items: MenuItem[];
        /** Top left corner in screen points. */
        x: number;
        y: number;
        width?: number;
        /** A submenu's parent's left edge: it opens to the left of it when there's no room on the right. */
        leftEdge?: number;
        onclose: () => void;
        nested?: boolean;
    } = $props();

    const stage = useStage();
    let node = $state<HTMLElement>();
    let open = $state<{ index: number; x: number; y: number; leftEdge: number } | null>(null);
    let position = $state({ left: 0, top: 0 });
    const hasChecks = $derived(items.some((i) => !i.separator && i.checked !== undefined));

    $effect(() => {
        if (!node) return;
        const screen = stage.size();
        const fits = x + node.offsetWidth <= screen.width - 4;
        position = {
            left: fits ? x : leftEdge !== undefined ? leftEdge - node.offsetWidth : screen.width - node.offsetWidth - 4,
            top: Math.max(26, Math.min(y, screen.height - node.offsetHeight - 4)),
        };
    });

    $effect(() => {
        if (nested) return;
        return dismissOnOutside(() => [...(stage.layer()?.querySelectorAll(".menu") ?? [])], onclose, true);
    });

    function hover(index: number, event: PointerEvent) {
        const item = items[index];
        if (item.separator || !item.submenu || item.disabled) {
            open = null;
            return;
        }
        const rect = stage.toStage((event.currentTarget as HTMLElement).getBoundingClientRect());
        open = { index, x: rect.x + rect.width + 6, y: rect.y - 5, leftEdge: position.left - 1 };
    }

    function choose(index: number) {
        const item = items[index];
        if (item.separator || item.disabled || item.submenu) return;
        item.action?.();
        onclose();
    }
</script>

<div
    bind:this={node}
    use:portal={stage.layer()}
    class="menu"
    role="menu"
    tabindex="-1"
    style:left="{position.left}px"
    style:top="{position.top}px"
    style:min-width={width ? `${width}px` : undefined}
>
    {#each items as item, i (i)}
        {#if item.separator}
            <div class="separator" role="separator"></div>
        {:else}
            <button
                class="item"
                class:disabled={item.disabled}
                class:open={open?.index === i}
                class:checks={hasChecks}
                role="menuitem"
                aria-disabled={item.disabled}
                onpointerenter={(e) => hover(i, e)}
                onclick={() => choose(i)}
            >
                {#if hasChecks}
                    <span class="check">{#if item.checked}<Check size={12} strokeWidth={2.6} />{/if}</span>
                {/if}
                {#if item.icon}<span class="icon"><item.icon size={14} strokeWidth={1.8} /></span>{/if}
                <span class="label">{item.label}</span>
                {#if item.shortcut}<span class="shortcut">{item.shortcut}</span>{/if}
                {#if item.submenu}<span class="arrow"><ChevronRight size={12} strokeWidth={2.4} /></span>{/if}
            </button>
        {/if}
    {/each}
</div>

{#if open}
    {@const item = items[open.index]}
    {#if !item.separator && item.submenu}
        <Self items={item.submenu} x={open.x} y={open.y} leftEdge={open.leftEdge} {onclose} nested />
    {/if}
{/if}

<style>
    .menu {
        position: absolute;
        z-index: 60;
        display: flex;
        flex-direction: column;
        padding: 5px;
        border-radius: 12px;
        background: var(--menu);
        -webkit-backdrop-filter: blur(30px) saturate(1.6);
        backdrop-filter: blur(30px) saturate(1.6);
        box-shadow:
            0 0 0 0.5px var(--window-edge),
            0 10px 30px rgb(0 0 0 / 0.22);
        color: var(--menu-text);
        font-size: 13px;
        white-space: nowrap;
        outline: none;
    }

    .item {
        display: flex;
        align-items: center;
        gap: 6px;
        height: 24px;
        padding: 0 10px 0 9px;
        border-radius: 7px;
        text-align: left;
    }

    .item.checks {
        padding-left: 4px;
    }

    .item:hover:not(.disabled),
    .item.open {
        background: var(--accent);
        color: #fff;
    }

    .item:hover:not(.disabled) .shortcut,
    .item.open .shortcut {
        color: rgb(255 255 255 / 0.85);
    }

    .disabled {
        color: var(--label-3);
    }

    .check {
        display: inline-flex;
        justify-content: center;
        width: 14px;
    }

    .icon {
        display: inline-flex;
    }

    .label {
        flex: 1;
    }

    .shortcut {
        margin-left: 24px;
        color: var(--label-2);
    }

    .arrow {
        display: inline-flex;
        margin-left: 18px;
    }

    .separator {
        height: 1px;
        margin: 5px 10px;
        background: var(--fill-3);
    }
</style>
