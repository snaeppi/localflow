<script lang="ts">
    // A popover in the screen's top layer, beside or under its anchor, closed by a click elsewhere or Esc.
    import type { Snippet } from "svelte";
    import { dismissOnOutside, portal, useStage } from "./stage";

    let {
        anchor,
        placement = "right",
        arrow = true,
        onclose,
        children,
        class: className = "",
    }: {
        anchor: HTMLElement;
        placement?: "right" | "below" | "below-end" | "over";
        arrow?: boolean;
        onclose: () => void;
        children: Snippet;
        class?: string;
    } = $props();

    const stage = useStage();
    let node = $state<HTMLElement>();
    let position = $state({ left: 0, top: 0 });

    $effect(() => {
        if (!node) return;
        const a = stage.toStage(anchor.getBoundingClientRect());
        const box = { width: node.offsetWidth, height: node.offsetHeight };
        const screen = stage.size();
        let left: number, top: number;
        if (placement === "right") {
            left = a.x + a.width + 8;
            top = a.y + a.height / 2 - box.height / 2;
        } else if (placement === "below") {
            left = a.x;
            top = a.y + a.height + 6;
        } else if (placement === "below-end") {
            left = a.x + a.width - box.width;
            top = a.y + a.height + 6;
        } else {
            left = a.x - 8;
            top = a.y - 5;
        }
        position = {
            left: Math.max(6, Math.min(left, screen.width - box.width - 6)),
            top: Math.max(30, Math.min(top, screen.height - box.height - 6)),
        };
    });

    $effect(() => dismissOnOutside(() => [node, anchor], onclose));
</script>

<div
    bind:this={node}
    use:portal={stage.layer()}
    class="popover {placement} {className}"
    class:arrow={arrow && placement === "right"}
    style:left="{position.left}px"
    style:top="{position.top}px"
>
    {@render children()}
</div>

<style>
    .popover {
        position: absolute;
        z-index: 50;
        background: var(--menu);
        -webkit-backdrop-filter: blur(30px) saturate(1.6);
        backdrop-filter: blur(30px) saturate(1.6);
        border-radius: 14px;
        box-shadow:
            0 0 0 0.5px var(--window-edge),
            0 10px 30px rgb(0 0 0 / 0.2);
        color: var(--menu-text);
        animation: appear 0.14s ease-out;
    }

    .arrow::before {
        content: "";
        position: absolute;
        left: -7px;
        top: calc(50% - 7px);
        border: 7px solid transparent;
        border-left: 0;
        border-right-color: var(--menu);
    }

    @keyframes appear {
        from {
            opacity: 0;
            transform: scale(0.97);
        }
    }
</style>
