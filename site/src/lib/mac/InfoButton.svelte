<script lang="ts">
    // An explanation behind an (i), opened by a click and shown to the right of the icon. [Links](url) work.
    import Info from "@lucide/svelte/icons/info";
    import Popover from "./Popover.svelte";

    let { text, label }: { text: string; label?: string } = $props();
    let button = $state<HTMLElement>();
    let shown = $state(false);

    /** Paragraphs, each a list of plain text and link parts. */
    const paragraphs = $derived(
        text.split("\n\n").map((p) =>
            p.split(/(\[[^\]]+\]\([^)]+\))/).map((part) => {
                const link = part.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
                return link ? { text: link[1], href: link[2] } : { text: part };
            }),
        ),
    );
</script>

<button
    bind:this={button}
    class="info"
    aria-label={label ? `More information about ${label}` : "More information"}
    aria-expanded={shown}
    onclick={() => (shown = !shown)}
>
    <Info size={11.5} strokeWidth={1.8} />
</button>

{#if shown && button}
    <Popover anchor={button} onclose={() => (shown = false)}>
        <div class="text">
            {#each paragraphs as parts, i (i)}
                <p>
                    {#each parts as part, j (j)}
                        {#if "href" in part}<a href={part.href} target="_blank" rel="noreferrer">{part.text}</a>{:else}{part.text}{/if}
                    {/each}
                </p>
            {/each}
        </div>
    </Popover>
{/if}

<style>
    .info {
        display: inline-flex;
        color: var(--label-2);
    }

    .text {
        width: 284px;
        padding: 18px 22px;
        font-size: 13px;
        line-height: 1.3;
    }

    p {
        margin: 0;
    }

    p + p {
        margin-top: 1em;
    }

    a {
        color: var(--accent);
    }
</style>
