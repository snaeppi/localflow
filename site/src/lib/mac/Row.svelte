<script lang="ts">
    // A title, an optional subtitle and (i) explanation, and a control on the trailing side
    // (Components.swift `SettingRow`).
    import type { Snippet } from "svelte";
    import InfoButton from "./InfoButton.svelte";

    let {
        title,
        subtitle,
        info,
        top = false,
        children,
    }: { title: string; subtitle?: string; info?: string; top?: boolean; children?: Snippet } = $props();
</script>

<div class="row" class:top>
    <div class="text">
        <div class="title">
            <span>{title}</span>
            {#if info}<InfoButton text={info} label={title} />{/if}
        </div>
        {#if subtitle}<div class="subtitle">{subtitle}</div>{/if}
    </div>
    <div class="control">{@render children?.()}</div>
</div>

<style>
    .row {
        display: flex;
        align-items: center;
        gap: 12px;
        min-height: 45px;
        padding: 9px 16px;
    }

    .top {
        align-items: flex-start;
    }

    .top .text {
        padding-top: 6px;
    }

    .text {
        display: flex;
        flex-direction: column;
        gap: 2px;
        flex: 1;
        min-width: 0;
    }

    .title {
        display: flex;
        align-items: center;
        gap: 6px;
    }

    .subtitle {
        font-size: 11px;
        color: var(--label-2);
    }

    .control {
        display: flex;
        align-items: center;
        flex-shrink: 0;
    }
</style>
