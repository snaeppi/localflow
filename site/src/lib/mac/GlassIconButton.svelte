<script lang="ts">
    // A round glass button with a symbol, as in the page headers. It gives under a press and springs back.
    import type { Snippet } from "svelte";

    let {
        label,
        onclick,
        onhover,
        children,
        element = $bindable(),
    }: {
        label: string;
        onclick: () => void;
        onhover?: (hovering: boolean) => void;
        children: Snippet;
        element?: HTMLElement;
    } = $props();
</script>

<button
    bind:this={element}
    class="glass-button"
    title={label}
    aria-label={label}
    {onclick}
    onpointerenter={() => onhover?.(true)}
    onpointerleave={() => onhover?.(false)}
>
    {@render children()}
</button>

<style>
    .glass-button {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 28px;
        height: 28px;
        border-radius: 50%;
        background: var(--glass) !important;
        box-shadow:
            inset 0 0 0 0.5px var(--glass-edge),
            inset 0 1px 0 var(--card-shine),
            0 1px 3px rgb(0 0 0 / 0.08);
        transition:
            transform 0.22s cubic-bezier(0.3, 1.6, 0.5, 1),
            background-color 0.15s;
        flex-shrink: 0;
    }

    .glass-button:hover {
        background-color: var(--fill-2);
        background-image: linear-gradient(var(--fill-2), var(--fill-2));
    }

    .glass-button:active {
        transform: scale(0.9);
        transition-duration: 0.1s;
    }
</style>
