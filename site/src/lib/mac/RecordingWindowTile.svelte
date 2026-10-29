<script lang="ts">
    // The recording window on or off, drawn small on a tile (Components.swift `RecordingWindowTile`).
    // Selecting On sends a dip through the pill's bars from left to right.
    import EyeOff from "@lucide/svelte/icons/eye-off";

    let { style, selected }: { style: "on" | "off"; selected: boolean } = $props();
    const heights = [4, 9, 6, 3, 8, 4, 6, 3];
    let wave = $state(0);
    let previous: boolean | undefined;

    $effect(() => {
        if (selected && previous === false) wave++;
        previous = selected;
    });
</script>

<span class="tile" class:selected>
    <span class="inner">
        {#if style === "on"}
            <span class="pill">
                {#key wave}
                    {#each heights as height, i (i)}
                        <span class="bar" class:dip={wave > 0} style:height="{height}px" style:animation-delay="{i * 45}ms"
                        ></span>
                    {/each}
                {/key}
            </span>
        {:else}
            <EyeOff size={16} strokeWidth={1.6} />
        {/if}
    </span>
</span>

<style>
    .tile {
        display: block;
        padding: 1px;
        border-radius: 11px;
        box-shadow: inset 0 0 0 2px transparent;
    }

    .selected {
        box-shadow: inset 0 0 0 2px var(--accent);
    }

    .inner {
        display: flex;
        align-items: center;
        justify-content: center;
        width: 94px;
        height: 44px;
        border-radius: 10px;
        background: var(--field);
        box-shadow: inset 0 0 0 1px var(--fill-3);
        color: var(--label-2);
    }

    .selected .inner {
        background: color-mix(in srgb, var(--accent) 12%, transparent);
    }

    .pill {
        display: flex;
        align-items: center;
        justify-content: center;
        gap: 1px;
        width: 50px;
        height: 20px;
        border-radius: 10px;
        background: #000;
    }

    .bar {
        width: 2px;
        border-radius: 1px;
        background: #fff;
    }

    /* Each bar dips to a third of its height over a quarter second, 45 ms after the one before it. */
    .dip {
        animation: dip 0.25s linear;
    }

    @keyframes dip {
        50% {
            transform: scaleY(0.35);
        }
    }
</style>
