<script lang="ts">
    // Subtitles for the demo, outside what the app shows: what's being said, and after a dictation the text
    // as it would be with cleanup switched the other way.
    import AudioLines from "@lucide/svelte/icons/audio-lines";
    import { dictation } from "../demo/dictation.svelte";

    const clip = $derived(dictation.scene.clip);
    const result = $derived(dictation.result);
    const visible = $derived(dictation.phase !== "idle" || dictation.heard > 0 || !!result);
</script>

<div class="caption" class:visible>
    <div class="line">
        <span class="label"><AudioLines size={13} strokeWidth={2} /> Said</span>
        <span class="words">
            {#each clip.words as word, i (i)}
                <span class:heard={word.start < dictation.heard || (!!result && !result.partial)}>{word.w}</span>{" "}
            {/each}
        </span>
    </div>
    {#if result?.other}
        <div class="line other">
            <span class="label">{result.cleaned ? "Before cleanup" : "With cleanup"}</span>
            <span class="words">{result.other}</span>
        </div>
    {/if}
</div>

<style>
    .caption {
        position: absolute;
        z-index: 20;
        left: 50%;
        bottom: 22px;
        width: 680px;
        transform: translateX(-50%);
        display: flex;
        flex-direction: column;
        gap: 6px;
        padding: 12px 16px;
        border-radius: 14px;
        background: rgb(20 20 22 / 0.78);
        -webkit-backdrop-filter: blur(20px);
        backdrop-filter: blur(20px);
        box-shadow: inset 0 0 0 0.5px rgb(255 255 255 / 0.12);
        color: #fff;
        font-size: 14px;
        line-height: 1.4;
        opacity: 0;
        transition: opacity 0.3s;
    }

    .caption.visible {
        opacity: 1;
    }

    .line {
        display: flex;
        gap: 12px;
    }

    .label {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        flex-shrink: 0;
        width: 116px;
        height: 1.4em;
        color: rgb(255 255 255 / 0.55);
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 0.04em;
        text-transform: uppercase;
    }

    .words span {
        color: rgb(255 255 255 / 0.3);
        transition: color 0.12s;
    }

    .words span.heard {
        color: #fff;
    }

    .other .words {
        white-space: pre-line;
        color: rgb(255 255 255 / 0.65);
    }
</style>
