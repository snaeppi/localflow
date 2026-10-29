<script lang="ts">
    // The microphone as a round glass button: its name on hover, the microphone list on click.
    import Headphones from "@lucide/svelte/icons/headphones";
    import Laptop from "@lucide/svelte/icons/laptop";
    import Monitor from "@lucide/svelte/icons/monitor";
    import Volume2 from "@lucide/svelte/icons/volume-2";
    import GlassIconButton from "./GlassIconButton.svelte";
    import Popover from "./Popover.svelte";
    import { microphones, settings } from "../settings.svelte";

    const symbols = { laptop: Laptop, display: Monitor, headphones: Headphones };
    let hovering = $state(false);
    let shown = $state(false);
    let button = $state<HTMLElement>();
    const Symbol = $derived(symbols[settings.microphoneSymbol]);

    function choose(id: string | null) {
        settings.microphone = id;
        shown = false;
    }
</script>

<div class="device">
    <span class="name" class:visible={hovering || shown}>{settings.microphoneName}</span>
    <GlassIconButton
        bind:element={button}
        label="Microphone: {settings.microphoneName}"
        onclick={() => (shown = !shown)}
        onhover={(h) => (hovering = h)}
    >
        <Symbol size={14} strokeWidth={1.7} />
    </GlassIconButton>
</div>

{#if shown && button}
    <Popover anchor={button} placement="below-end" arrow={false} onclose={() => (shown = false)} class="device-menu">
        <div class="list">
            <button
                class="row"
                title="Uses the system input, but skips Bluetooth headsets: their microphones are less accurate and slow to start."
                onclick={() => choose(null)}
            >
                <span class="symbol" class:selected={settings.microphone === null}><Volume2 size={11} strokeWidth={2} /></span>
                Automatic
            </button>
            {#each microphones as device (device.id)}
                {@const Icon = symbols[device.symbol]}
                <button class="row" onclick={() => choose(device.id)}>
                    <span class="symbol" class:selected={settings.microphone === device.id}><Icon size={11} strokeWidth={2} /></span>
                    {device.name}
                </button>
            {/each}
        </div>
    </Popover>
{/if}

<style>
    .device {
        display: flex;
        align-items: center;
        gap: 10px;
    }

    .name {
        font-size: 12px;
        font-weight: 500;
        color: var(--label-2);
        opacity: 0;
        transition: opacity 0.15s ease-out;
        white-space: nowrap;
    }

    .name.visible {
        opacity: 1;
    }

    .list {
        display: flex;
        flex-direction: column;
        min-width: 250px;
        padding: 4px;
    }

    :global(.device-menu) {
        border-radius: 20px !important;
    }

    .row {
        display: flex;
        align-items: center;
        gap: 10px;
        height: 32px;
        padding: 0 8px;
        border-radius: 12px;
        text-align: left;
    }

    .row:hover {
        background: var(--fill-2) !important;
    }

    .symbol {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 22px;
        height: 22px;
        border-radius: 50%;
        background: var(--fill-3);
        color: var(--label-2);
    }

    .symbol.selected {
        background: var(--accent);
        color: #fff;
    }
</style>
