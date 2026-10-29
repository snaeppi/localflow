<script lang="ts">
    // A 32 × 14 pt switch (Components.swift `Switch`: the mini system switch at 8/9 size).
    let {
        checked = $bindable(false),
        disabled = false,
        label,
        onchange,
    }: { checked?: boolean; disabled?: boolean; label: string; onchange?: (on: boolean) => void } = $props();

    function toggle() {
        if (disabled) return;
        checked = !checked;
        onchange?.(checked);
    }
</script>

<button class="switch" class:on={checked} {disabled} role="switch" aria-checked={checked} aria-label={label} onclick={toggle}>
    <span class="knob"></span>
</button>

<style>
    .switch {
        position: relative;
        width: 32px;
        height: 14px;
        border-radius: 7px;
        background: var(--switch-off) !important;
        transition: background 0.2s;
        flex-shrink: 0;
    }

    .switch.on {
        background: var(--accent) !important;
    }

    .switch:disabled {
        opacity: 0.45;
    }

    .knob {
        position: absolute;
        top: 1.5px;
        left: 1.5px;
        width: 19px;
        height: 11px;
        border-radius: 5.5px;
        background: var(--knob);
        box-shadow:
            0 0 0 0.5px rgb(0 0 0 / 0.08),
            0 1px 2px rgb(0 0 0 / 0.2);
        transition: transform 0.22s cubic-bezier(0.3, 0.7, 0.3, 1);
    }

    .on .knob {
        transform: translateX(10px);
    }

    .switch:active:not(:disabled) .knob {
        width: 22px;
    }

    .on:active:not(:disabled) .knob {
        transform: translateX(7px);
    }
</style>
