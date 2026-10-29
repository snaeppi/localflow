<script lang="ts">
    // Rows on a rounded glass panel (Components.swift `Card`); separate rows with Divider.
    import type { Snippet } from "svelte";

    let { children, style = "" }: { children: Snippet; style?: string } = $props();
</script>

<div class="card" {style}>{@render children()}</div>

<style>
    .card {
        display: flex;
        flex-direction: column;
        border-radius: 18px;
        background: var(--card);
        box-shadow:
            inset 0 0 0 0.5px var(--card-edge),
            inset 0 1px 0 var(--card-shine),
            var(--card-shadow);
    }
</style>
