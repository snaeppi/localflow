<script lang="ts" generics="T extends string">
    // Picture tiles with a caption; each tile draws its own selection ring.
    import type { Snippet } from "svelte";

    let {
        value,
        options,
        spacing = 18,
        onchange,
        tile,
    }: {
        value: T;
        options: { value: T; title: string }[];
        spacing?: number;
        onchange: (value: T) => void;
        tile: Snippet<[T, boolean]>;
    } = $props();
</script>

<div class="tiles" style:gap="{spacing}px">
    {#each options as option (option.value)}
        {@const selected = option.value === value}
        <button class="choice" aria-pressed={selected} aria-label={option.title} onclick={() => onchange(option.value)}>
            {@render tile(option.value, selected)}
            <span class="caption" class:selected>{option.title}</span>
        </button>
    {/each}
</div>

<style>
    .tiles {
        display: flex;
        align-items: flex-start;
    }

    .choice {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 6px;
    }

    .caption {
        font-size: 12px;
        font-weight: 600;
        color: var(--label-2);
    }

    .caption.selected {
        color: var(--label);
    }
</style>
