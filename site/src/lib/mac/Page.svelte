<script lang="ts">
    // A Settings page: its title row level with the traffic lights (PageHeader), and content that scrolls
    // under it, fading out toward the top edge, and optionally under a bar at the bottom.
    import type { Snippet } from "svelte";
    import ChevronLeft from "@lucide/svelte/icons/chevron-left";
    import GlassIconButton from "./GlassIconButton.svelte";
    import InfoButton from "./InfoButton.svelte";

    let {
        title,
        info,
        back,
        trailing,
        bottom,
        children,
        wide = false,
    }: {
        title: string;
        info?: string;
        back?: () => void;
        trailing?: Snippet;
        bottom?: Snippet;
        children: Snippet;
        /** Content without the 520 pt column (the vocabulary list). */
        wide?: boolean;
    } = $props();
</script>

<div class="page">
    <div class="scroll" class:has-bottom={!!bottom}>
        <div class="content" class:wide>{@render children()}</div>
    </div>
    <div class="blur top"></div>
    <header>
        {#if back}
            <span class="back">
                <GlassIconButton label="Back" onclick={back}><ChevronLeft size={14} strokeWidth={2.2} /></GlassIconButton>
            </span>
        {/if}
        <span class="title">{title}</span>
        {#if info}<InfoButton text={info} />{/if}
        <span class="spacer"></span>
        {@render trailing?.()}
    </header>
    {#if bottom}
        <div class="blur bottom-blur"></div>
        <div class="bottom">{@render bottom()}</div>
    {/if}
</div>

<style>
    .page {
        position: relative;
        height: 100%;
        overflow: hidden;
    }

    .scroll {
        position: absolute;
        inset: 0;
        overflow-y: auto;
        padding-top: 48px;
        scrollbar-width: thin;
        /* Content fades out toward the window edge under the header (Components.swift `ScrollEdgeFade`). */
        -webkit-mask-image: linear-gradient(
            to bottom,
            rgb(0 0 0 / 0.07) 0,
            rgb(0 0 0 / 0.28) 12px,
            rgb(0 0 0 / 0.63) 20px,
            rgb(0 0 0 / 0.83) 28px,
            rgb(0 0 0 / 0.93) 38px,
            #000 46px
        );
        mask-image: linear-gradient(
            to bottom,
            rgb(0 0 0 / 0.07) 0,
            rgb(0 0 0 / 0.28) 12px,
            rgb(0 0 0 / 0.63) 20px,
            rgb(0 0 0 / 0.83) 28px,
            rgb(0 0 0 / 0.93) 38px,
            #000 46px
        );
    }

    .scroll.has-bottom {
        padding-bottom: 73px;
        -webkit-mask-image:
            linear-gradient(
                to bottom,
                rgb(0 0 0 / 0.07) 0,
                rgb(0 0 0 / 0.63) 20px,
                #000 46px,
                #000 calc(100% - 73px),
                rgb(0 0 0 / 0.07) 100%
            );
        mask-image: linear-gradient(
            to bottom,
            rgb(0 0 0 / 0.07) 0,
            rgb(0 0 0 / 0.63) 20px,
            #000 46px,
            #000 calc(100% - 73px),
            rgb(0 0 0 / 0.07) 100%
        );
    }

    .content {
        max-width: 568px;
        margin: 0 auto;
        padding: 16px 24px 24px;
        display: flex;
        flex-direction: column;
        gap: 10px;
    }

    .content.wide {
        max-width: none;
        padding-top: 16px;
        gap: 0;
    }

    .blur {
        position: absolute;
        left: 0;
        right: 0;
        pointer-events: none;
        -webkit-backdrop-filter: blur(4px);
        backdrop-filter: blur(4px);
    }

    .blur.top {
        top: 0;
        height: 60px;
        -webkit-mask-image: linear-gradient(#000 30%, transparent);
        mask-image: linear-gradient(#000 30%, transparent);
    }

    .bottom-blur {
        bottom: 0;
        height: 80px;
        -webkit-mask-image: linear-gradient(transparent, #000 70%);
        mask-image: linear-gradient(transparent, #000 70%);
    }

    header {
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 48px;
        display: flex;
        align-items: center;
        gap: 7px;
        padding: 0 10px 0 16px;
    }

    .back {
        margin: 0 5px 0 -6px;
        display: inline-flex;
    }

    .title {
        font-weight: 600;
    }

    .spacer {
        flex: 1;
    }

    .bottom {
        position: absolute;
        left: 0;
        right: 0;
        bottom: 0;
        padding: 14px 24px;
    }
</style>
