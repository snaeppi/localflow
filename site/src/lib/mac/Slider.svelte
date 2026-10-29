<script lang="ts">
    // A slider with tick marks for its steps and a speaker at each end, as on the Sound page.
    import Volume from "@lucide/svelte/icons/volume";
    import Volume2 from "@lucide/svelte/icons/volume-2";

    let {
        value,
        step = 0.1,
        label,
        onchange,
        onend,
    }: { value: number; step?: number; label: string; onchange: (v: number) => void; onend?: () => void } = $props();
    const ticks = $derived(Math.round(1 / step) + 1);
</script>

<div class="slider">
    <span class="secondary icon"><Volume size={13} strokeWidth={1.8} /></span>
    <div class="track-area" style:--fraction={value}>
        <input
            type="range"
            min="0"
            max="1"
            {step}
            {value}
            aria-label={label}
            oninput={(e) => onchange(Number(e.currentTarget.value))}
            onchange={() => onend?.()}
        />
        <div class="ticks">
            {#each { length: ticks } as _, i (i)}<span></span>{/each}
        </div>
    </div>
    <span class="secondary icon"><Volume2 size={13} strokeWidth={1.8} /></span>
</div>

<style>
    .slider {
        display: flex;
        align-items: center;
        gap: 8px;
        width: 230px;
    }

    .icon {
        display: inline-flex;
    }

    .track-area {
        position: relative;
        flex: 1;
        height: 22px;
    }

    input {
        -webkit-appearance: none;
        appearance: none;
        position: absolute;
        inset: 0 0 6px 0;
        width: 100%;
        margin: 0;
        background: transparent;
    }

    input::-webkit-slider-runnable-track {
        height: 3px;
        border-radius: 2px;
        background: linear-gradient(to right, var(--accent) calc(var(--fraction) * 100%), var(--fill-3) 0);
    }

    input::-moz-range-track {
        height: 3px;
        border-radius: 2px;
        background: linear-gradient(to right, var(--accent) calc(var(--fraction) * 100%), var(--fill-3) 0);
    }

    input::-webkit-slider-thumb {
        -webkit-appearance: none;
        width: 19px;
        height: 15px;
        margin-top: -6px;
        border-radius: 8px;
        background: var(--knob);
        box-shadow:
            0 0 0 0.5px rgb(0 0 0 / 0.1),
            0 1px 3px rgb(0 0 0 / 0.25);
    }

    input::-moz-range-thumb {
        width: 19px;
        height: 15px;
        border: 0;
        border-radius: 8px;
        background: var(--knob);
        box-shadow:
            0 0 0 0.5px rgb(0 0 0 / 0.1),
            0 1px 3px rgb(0 0 0 / 0.25);
    }

    .ticks {
        position: absolute;
        left: 9px;
        right: 9px;
        bottom: 1px;
        display: flex;
        justify-content: space-between;
        pointer-events: none;
    }

    .ticks span {
        width: 2px;
        height: 2px;
        border-radius: 1px;
        background: var(--label-3);
    }
</style>
