<script lang="ts">
    // The recording window (RecordingWindow.swift): a black pill with the live waveform while recording,
    // opening under the pointer into a stop button; with "Always show", a sliver between dictations that
    // opens into three buttons (cleanup, start dictating, Settings). It can be dragged to 17 places.
    import Clipboard from "@lucide/svelte/icons/clipboard";
    import Eraser from "@lucide/svelte/icons/eraser";
    import Gear from "@lucide/svelte/icons/settings";
    import Mark from "./Mark.svelte";
    import Menu from "./Menu.svelte";
    import { useStage } from "./stage";
    import { dictation } from "../demo/dictation.svelte";
    import { toggleCleanup } from "../cleanup";
    import { navigation, settings, title } from "../settings.svelte";

    let { menuBarHeight }: { menuBarHeight: number } = $props();
    const stage = useStage();

    type Row = "top" | "upper" | "middle" | "lower" | "bottom";
    type Spot = { column: number; row: Row };
    const spots: Spot[] = [
        ...[0, 1, 2, 3, 4].flatMap((column) => [
            { column, row: "top" as Row },
            { column, row: "bottom" as Row },
        ]),
        ...[0, 4].flatMap((column) => (["upper", "middle", "lower"] as Row[]).map((row) => ({ column, row }))),
        { column: 2, row: "middle" },
    ];
    const sizes = { sliver: [50, 9], compact: [59, 30], expanded: [141, 37], notice: [260, 30] } as const;
    const red = "rgb(255 69 59)";

    let spot = $state<Spot>({ column: 2, row: "top" });
    let expanded = $state(false);
    let pointer = $state<"pill" | "cleanup" | "record" | "settings" | null>(null);
    let tooltipPart = $state<typeof pointer>(null);
    let drag = $state<{ x: number; y: number; dx: number; dy: number; moved: boolean } | null>(null);
    let contextMenu = $state<{ x: number; y: number } | null>(null);
    let dragStart = { x: 0, y: 0 };
    let openTimer: ReturnType<typeof setTimeout> | undefined;
    let tooltipTimer: ReturnType<typeof setTimeout> | undefined;
    let canvas = $state<HTMLCanvasElement>();
    let small = $state<HTMLCanvasElement>();
    let pillNode = $state<HTMLElement>();

    const mode = $derived(
        dictation.notice
            ? "notice"
            : dictation.phase === "recording" && dictation.shown
              ? "listening"
              : dictation.phase === "finishing" && dictation.shown
                ? "transcribing"
                : "hidden",
    );
    const idleShown = $derived(settings.recordingWindow === "on" && settings.alwaysShow);
    const shown = $derived(mode !== "hidden" || idleShown);
    const interactive = $derived(mode === "listening" || mode === "transcribing" || (mode === "hidden" && idleShown));
    const shape = $derived(
        mode === "notice"
            ? "notice"
            : mode === "hidden"
              ? expanded || drag?.moved
                  ? "expanded"
                  : "sliver"
              : expanded || drag?.moved
                ? "expanded"
                : "compact",
    );
    const open = $derived(shape === "expanded");
    const idle = $derived(mode === "hidden");
    const recording = $derived(mode === "listening");
    const wave = $derived(open && !idle);
    const buttons = $derived(open && idle);
    const [width, height] = $derived(sizes[shape]);

    const screen = $derived(stage.size());
    function spotCenter(s: Spot, h: number) {
        const visible = { top: menuBarHeight, height: screen.height - menuBarHeight };
        const x = 120 + (s.column * (screen.width - 240)) / 4;
        const y =
            s.row === "top"
                ? visible.top + 4 + h / 2
                : s.row === "bottom"
                  ? screen.height - 4 - h / 2
                  : visible.top + { upper: 0.25, middle: 0.5, lower: 0.7 }[s.row] * visible.height;
        return { x, y };
    }
    const anchor = $derived(spot.row === "top" ? "top" : spot.row === "bottom" ? "bottom" : "center");
    const center = $derived(drag?.moved ? { x: drag.x, y: drag.y } : spotCenter(spot, height));
    const nearest = $derived(
        drag?.moved
            ? spots.reduce((best, s) => {
                  const c = spotCenter(s, sizes.expanded[1]);
                  const b = spotCenter(best, sizes.expanded[1]);
                  return Math.hypot(c.x - drag!.x, c.y - drag!.y) < Math.hypot(b.x - drag!.x, b.y - drag!.y) ? s : best;
              })
            : null,
    );

    const tooltip = $derived.by(() => {
        if (!open || drag || !tooltipPart) return null;
        const shortcut = settings.toggleShortcut ?? settings.pushToTalk;
        const key = shortcut ? title(shortcut) : null;
        if (tooltipPart === "record" && idle) return { text: "Start dictation", key };
        if (tooltipPart === "record" && recording) return { text: "Finish dictation", key };
        if (tooltipPart === "cleanup" && idle) return { text: settings.cleansUp ? "Turn off cleanup" : "Turn on cleanup", key: null };
        if (tooltipPart === "settings" && idle) return { text: "Open Settings", key: null };
        return null;
    });

    const highlight = $derived.by(() => {
        if (!open) return null;
        if (recording) return { x: -47, color: pointer === "record" ? "rgb(255 69 59 / 0.4)" : "rgb(255 69 59 / 0.28)" };
        if (!idle) return { x: -47, color: "rgb(255 255 255 / 0.14)" };
        if (pointer === "cleanup") return { x: -47, color: "rgb(255 255 255 / 0.2)" };
        if (pointer === "record") return { x: 0, color: "rgb(255 255 255 / 0.2)" };
        if (pointer === "settings") return { x: 47, color: "rgb(255 255 255 / 0.2)" };
        return null;
    });

    // Closing when the pill stops being interactive (a dictation ended under the pointer).
    $effect(() => {
        if (!interactive) leave();
    });

    function enter() {
        if (!interactive || expanded || openTimer) return;
        openTimer = setTimeout(() => {
            openTimer = undefined;
            expanded = true;
        }, 300);
    }

    function leave() {
        clearTimeout(openTimer);
        clearTimeout(tooltipTimer);
        openTimer = undefined;
        expanded = false;
        pointer = null;
        tooltipPart = null;
    }

    function move(event: PointerEvent) {
        if (drag) return;
        if (!expanded) {
            pointer = "pill";
            return;
        }
        const rect = pillNode!.getBoundingClientRect();
        const s = stage.toStage(rect);
        const scale = rect.width / s.width;
        const dx = (event.clientX - (rect.left + rect.width / 2)) / scale;
        const part = idle ? (dx < -23.5 ? "cleanup" : dx > 23.5 ? "settings" : "record") : dx < -23.5 ? "record" : "pill";
        if (part === pointer) return;
        pointer = part;
        clearTimeout(tooltipTimer);
        if (tooltipPart) tooltipPart = part;
        else tooltipTimer = setTimeout(() => (tooltipPart = pointer), 450);
    }

    function tap() {
        if (pointer === "record") {
            dictation.stopAutoplay();
            dictation.toggle();
        } else if (pointer === "cleanup" && idle) toggleCleanup();
        else if (pointer === "settings" && idle) {
            dictation.stopAutoplay();
            navigation.mode = "settings";
        }
    }

    function pointerdown(event: PointerEvent) {
        if (event.button !== 0 || !interactive) return;
        (event.currentTarget as HTMLElement).setPointerCapture(event.pointerId);
        const p = stage.toStage(new DOMRect(event.clientX, event.clientY, 0, 0));
        dragStart = p;
        drag = { x: center.x, y: center.y, dx: p.x - center.x, dy: p.y - center.y, moved: false };
    }

    function pointermove(event: PointerEvent) {
        if (!drag) return;
        const p = stage.toStage(new DOMRect(event.clientX, event.clientY, 0, 0));
        if (!drag.moved && Math.hypot(p.x - dragStart.x, p.y - dragStart.y) < 3) return;
        drag = { ...drag, x: p.x - drag.dx, y: p.y - drag.dy, moved: true };
        tooltipPart = null;
    }

    function pointerup() {
        if (!drag) return;
        const moved = drag.moved;
        if (moved && nearest) spot = nearest;
        drag = null;
        if (!moved) tap();
    }

    // The waveforms, redrawn every frame while they show.
    function draw(node: HTMLCanvasElement | undefined, bars: number, w: number, h: number, shimmer: boolean, now: number) {
        if (!node) return;
        const dpr = window.devicePixelRatio * 2;
        if (node.width !== w * dpr) {
            node.width = w * dpr;
            node.height = h * dpr;
        }
        const g = node.getContext("2d")!;
        g.setTransform(dpr, 0, 0, dpr, 0, 0);
        g.clearRect(0, 0, w, h);
        const levels = dictation.waveform.bars.slice(-bars);
        const barWidth = 2;
        const gap = (w - barWidth * bars) / (bars - 1);
        const minHeight = 2;
        levels.forEach((level, i) => {
            let height: number;
            let opacity = 0.9;
            if (shimmer) {
                const phase = (now / 1000) * 2.2 - (i / bars) * 2;
                const wave = (Math.sin(phase * Math.PI) + 1) / 2;
                height = minHeight + wave * (h * 0.4);
                opacity = 0.35 + 0.55 * wave;
            } else {
                height = minHeight + level * (h - minHeight);
            }
            height = Math.min(height, h);
            g.fillStyle = `rgb(255 255 255 / ${opacity})`;
            g.beginPath();
            g.roundRect(i * (barWidth + gap), (h - height) / 2, barWidth, height, barWidth / 2);
            g.fill();
        });
    }

    $effect(() => {
        if (mode !== "listening" && mode !== "transcribing") return;
        let frame = 0;
        const step = (now: number) => {
            const shimmer = mode === "transcribing";
            draw(canvas, 14, 72, 16, shimmer, now);
            draw(small, 6, 33, 14, shimmer, now);
            frame = requestAnimationFrame(step);
        };
        frame = requestAnimationFrame(step);
        return () => cancelAnimationFrame(frame);
    });
</script>

{#if drag?.moved}
    {#each spots as s, i (i)}
        {@const c = spotCenter(s, sizes.expanded[1])}
        <div
            class="zone"
            class:on={nearest === s}
            style:left="{c.x - sizes.expanded[0] / 2}px"
            style:top="{c.y - sizes.expanded[1] / 2}px"
        ></div>
    {/each}
{/if}

<div
    class="anchor {anchor}"
    class:dragging={drag?.moved}
    style:left="{center.x}px"
    style:top="{center.y}px"
>
    <div
        class="reach"
        class:open
        class:interactive
        role="presentation"
        style:width="{width + (open ? 32 : 100)}px"
        style:height="{height + (open ? 28 : 44)}px"
        onpointerenter={enter}
        onpointerleave={() => !drag && leave()}
        onpointermove={move}
    >
        <div
            bind:this={pillNode}
            class="pill"
            class:shown
            class:sliver={shape === "sliver"}
            class:notice={shape === "notice"}
            style:width={shape === "notice" ? undefined : `${width}px`}
            style:height="{height}px"
            role="button"
            tabindex="-1"
            aria-label="Recording window"
            onpointerdown={pointerdown}
            onpointermove={pointermove}
            onpointerup={pointerup}
            onkeydown={() => {}}
            aria-hidden={!shown}
            oncontextmenu={(e) => {
                if (!interactive) return;
                e.preventDefault();
                const p = stage.toStage(new DOMRect(e.clientX, e.clientY, 0, 0));
                contextMenu = { x: p.x, y: p.y };
            }}
        >
            <span class="circle" style:transform="translateX({highlight?.x ?? (wave ? -47 : 0)}px)" style:background={highlight?.color ?? "transparent"}
            ></span>
            <span class="side" style:transform="translateX(-47px)" style:opacity={buttons ? (settings.cleansUp ? 1 : 0.45) : 0} class:visible={buttons}>
                <Eraser size={15} strokeWidth={2.2} />
            </span>
            <span class="side" style:transform="translateX(47px)" style:opacity={buttons ? 1 : 0} class:visible={buttons}>
                <Gear size={15} strokeWidth={2.2} />
            </span>
            <span
                class="logo"
                class:visible={open}
                style:transform="translateX({wave ? -47 : 0}px)"
                style:color={recording ? red : mode === "transcribing" ? "rgb(255 255 255 / 0.85)" : "#fff"}
                style:transition-delay={wave ? "0s" : "0.1s"}
            >
                <Mark width={22} />
            </span>
            <canvas bind:this={canvas} class="wave big" class:visible={wave} style="width: 72px; height: 16px"></canvas>
            <canvas bind:this={small} class="wave" class:visible={shape === "compact"} style="width: 33px; height: 14px"></canvas>
            {#if shape === "notice" && dictation.notice}
                <span class="notice-text">
                    <Clipboard size={13} strokeWidth={2} />
                    {dictation.notice}
                </span>
            {/if}
        </div>
        {#if tooltip}
            <div class="tooltip" class:above={spot.row === "bottom"} style:--distance="{height / 2 + 10 + 37 / 2}px">
                <span>{tooltip.text}</span>
                {#if tooltip.key}<span class="key">{tooltip.key}</span>{/if}
            </div>
        {/if}
    </div>
</div>

{#if contextMenu}
    <Menu
        x={contextMenu.x}
        y={contextMenu.y}
        onclose={() => (contextMenu = null)}
        items={[
            {
                label: "Open Settings…",
                action: () => {
                    dictation.stopAutoplay();
                    navigation.mode = "settings";
                },
            },
            { label: "Copy Last Transcript", disabled: !dictation.lastTranscript, action: () => navigator.clipboard?.writeText(dictation.lastTranscript ?? "") },
        ]}
    />
{/if}

<style>
    .anchor {
        position: absolute;
        z-index: 40;
        width: 0;
        height: 0;
        display: flex;
        justify-content: center;
        align-items: center;
    }

    .reach {
        position: absolute;
        display: flex;
        align-items: center;
        justify-content: center;
        pointer-events: none;
    }

    .reach.interactive {
        pointer-events: auto;
    }

    .pill {
        position: relative;
        flex-shrink: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        border-radius: 999px;
        background: rgb(10 10 10);
        box-shadow: inset 0 0 0 0.75px rgb(255 255 255 / 0.14);
        color: #fff;
        overflow: hidden;
        opacity: 0;
        transform: scale(0.6);
        transition:
            width 0.28s cubic-bezier(0.25, 0.9, 0.3, 1) 0.03s,
            height 0.28s cubic-bezier(0.25, 0.9, 0.3, 1) 0.03s,
            opacity 0.28s,
            transform 0.28s cubic-bezier(0.25, 0.9, 0.3, 1),
            background-color 0.2s;
        pointer-events: auto;
        touch-action: none;
    }

    .pill:not(.shown) {
        pointer-events: none;
    }

    .pill.shown {
        opacity: 1;
        transform: scale(1);
    }

    .pill.sliver {
        background: rgb(0 0 0 / 0.45);
        box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.4);
    }

    .pill.notice {
        padding: 0 14px;
    }

    .circle {
        position: absolute;
        width: 31px;
        height: 31px;
        border-radius: 50%;
        transition:
            transform 0.2s cubic-bezier(0.25, 0.9, 0.3, 1),
            background-color 0.2s ease-out;
    }

    .side,
    .logo {
        position: absolute;
        display: flex;
        align-items: center;
        justify-content: center;
        width: 31px;
        height: 31px;
        transition: opacity 0.08s ease-out;
    }

    .side.visible,
    .logo.visible {
        transition:
            opacity 0.16s ease-out 0.16s,
            transform 0.22s cubic-bezier(0.25, 0.9, 0.3, 1),
            color 0.2s ease-out;
    }

    .logo {
        opacity: 0;
        transition:
            opacity 0.08s ease-out,
            transform 0.22s cubic-bezier(0.25, 0.9, 0.3, 1),
            color 0.2s ease-out;
    }

    .logo.visible {
        opacity: 1;
    }

    .wave {
        position: absolute;
        opacity: 0;
        transition: opacity 0.08s ease-out;
    }

    .wave.big {
        transform: translateX(23px);
    }

    .wave.visible {
        opacity: 1;
        transition: opacity 0.16s ease-out 0.16s;
    }

    .notice-text {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        font-size: 12px;
        font-weight: 500;
        white-space: nowrap;
        animation: fade-in 0.16s ease-out 0.16s both;
    }

    @keyframes fade-in {
        from {
            opacity: 0;
        }
    }

    .tooltip {
        position: absolute;
        top: 50%;
        display: flex;
        align-items: center;
        gap: 10px;
        height: 37px;
        padding: 0 12px;
        border-radius: 10px;
        background: rgb(18 18 18 / 0.96);
        box-shadow: inset 0 0 0 0.75px rgb(255 255 255 / 0.12);
        color: rgb(255 255 255 / 0.85);
        font-size: 13px;
        white-space: nowrap;
        transform: translateY(calc(-50% + var(--distance)));
        pointer-events: none;
        animation: fade-in 0.2s ease-out;
    }

    .tooltip.above {
        transform: translateY(calc(-50% - var(--distance)));
    }

    .key {
        display: inline-flex;
        align-items: center;
        min-height: 22px;
        padding: 0 7px;
        border-radius: 5px;
        background: rgb(255 255 255 / 0.14);
        color: #fff;
        font-size: 12px;
        font-weight: 600;
    }

    .zone {
        position: absolute;
        z-index: 39;
        width: 141px;
        height: 37px;
        border-radius: 999px;
        background: rgb(0 0 0 / 0.22);
        box-shadow: inset 0 0 0 1px rgb(255 255 255 / 0.3);
        transition: box-shadow 0.15s ease-out;
    }

    .zone.on {
        box-shadow: inset 0 0 0 2.5px var(--accent);
    }
</style>
