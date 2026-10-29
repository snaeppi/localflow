<script lang="ts">
    // Localflow's mark in the current colour.
    import { markPath, markViewBox } from "./mark-path";

    let { width, style = "" }: { width: number; style?: string } = $props();
</script>

<svg {width} height={(width * 374.92245) / 655.61924} viewBox={markViewBox} {style} aria-hidden="true">
    <path d={markPath} fill="currentColor" />
</svg>

<style>
    svg {
        display: block;
    }
</style>
