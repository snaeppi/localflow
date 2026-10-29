<script lang="ts">
    // Horizontal bars, one axis per chart: Localflow in the accent colour, other runtimes in gray. Each bar
    // has its value at the tip and the p90 on hover or focus; the table view has every number.
    import type { Chart } from "./speed";

    let { chart }: { chart: Chart } = $props();
    let table = $state(false);
    let hovered = $state<string | null>(null);

    const max = $derived(Math.max(...chart.groups.flatMap((g) => g.bars.map((b) => b.value))));
    /** Round tick steps: 1, 2, 2.5 or 5 × 10ⁿ, about five of them. */
    const ticks = $derived.by(() => {
        const raw = max / 5;
        const magnitude = 10 ** Math.floor(Math.log10(raw));
        const step = [1, 2, 2.5, 5, 10].map((m) => m * magnitude).find((s) => s >= raw)!;
        const top = Math.ceil(max / step) * step;
        return Array.from({ length: top / step + 1 }, (_, i) => i * step);
    });
    const top = $derived(ticks[ticks.length - 1]);
    const format = (ms: number) => `${ms.toLocaleString("en-US")} ms`;
</script>

<figure class="chart">
    <figcaption>
        <h3>{chart.title}</h3>
        <p>{chart.subtitle}</p>
    </figcaption>

    {#if table}
        <table>
            <thead><tr><th></th><th>Median</th><th>p90</th></tr></thead>
            <tbody>
                {#each chart.groups as group, g (g)}
                    {#if group.label}<tr class="group"><th colspan="3">{group.label}</th></tr>{/if}
                    {#each group.bars as bar, i (i)}
                        <tr>
                            <th>{bar.name}{#if bar.detail}<span class="detail"> · {bar.detail}</span>{/if}</th>
                            <td>{format(bar.value)}</td>
                            <td>{bar.p90 ? format(bar.p90) : "–"}</td>
                        </tr>
                    {/each}
                {/each}
            </tbody>
        </table>
    {:else}
        <div class="plot">
            {#each chart.groups as group, g (g)}
                {#if group.label}<div class="group-label">{group.label}</div>{/if}
                {#each group.bars as bar, i (i)}
                    {@const id = `${g}-${i}`}
                    <div class="bar-row">
                        <div class="name">
                            <span>{bar.name}</span>
                            {#if bar.detail}<span class="detail">{bar.detail}</span>{/if}
                        </div>
                        <div class="track">
                            {#each ticks as tick (tick)}
                                <span class="grid" style:left="{(tick / top) * 100}%"></span>
                            {/each}
                            <button
                                class="bar"
                                class:accent={bar.localflow}
                                class:lift={hovered === id}
                                style:width="{Math.max(0.6, (bar.value / top) * 100)}%"
                                aria-label="{bar.name}{bar.detail ? `, ${bar.detail}` : ''}: median {format(bar.value)}{bar.p90 ? `, p90 ${format(bar.p90)}` : ''}"
                                onpointerenter={() => (hovered = id)}
                                onpointerleave={() => (hovered = null)}
                                onfocus={() => (hovered = id)}
                                onblur={() => (hovered = null)}
                            ></button>
                            <span class="value" style:left="calc({(bar.value / top) * 100}% + 8px)">
                                {format(bar.value)}
                                {#if hovered === id && bar.p90}<span class="p90">p90 {format(bar.p90)}</span>{/if}
                            </span>
                        </div>
                    </div>
                {/each}
            {/each}
            <div class="axis">
                <div class="name"></div>
                <div class="track">
                    {#each ticks as tick (tick)}
                        <span class="tick" style:left="{(tick / top) * 100}%">{tick.toLocaleString("en-US")}</span>
                    {/each}
                </div>
            </div>
        </div>
    {/if}
    <button class="toggle" onclick={() => (table = !table)}>{table ? "Show chart" : "Show table"}</button>
</figure>

<style>
    .chart {
        container-type: inline-size;
        --bar: #8e8d86;
        --accent-bar: #2a78d6;
        --grid: #ecebe6;
        margin: 0;
        padding: 22px 22px 16px;
        border-radius: 16px;
        background: var(--surface);
        box-shadow:
            0 0 0 1px var(--line),
            var(--shadow);
    }

    @media (prefers-color-scheme: dark) {
        .chart {
            --bar: #706f68;
            --accent-bar: #3987e5;
            --grid: #262624;
        }
    }

    h3 {
        margin: 0;
        font-size: 17px;
        font-weight: 600;
    }

    figcaption p {
        margin: 4px 0 16px;
        color: var(--text-2);
        font-size: 14px;
    }

    .group-label {
        margin: 14px 0 4px;
        font-size: 13px;
        font-weight: 600;
        color: var(--text-2);
    }

    .group-label:first-child {
        margin-top: 0;
    }

    .bar-row,
    .axis {
        display: grid;
        grid-template-columns: minmax(130px, 34%) 1fr;
        gap: 14px;
        align-items: center;
    }

    .bar-row {
        min-height: 40px;
    }

    .name {
        display: flex;
        flex-direction: column;
        font-size: 14px;
        line-height: 1.25;
    }

    .detail {
        color: var(--text-3);
        font-size: 12px;
    }

    .track {
        position: relative;
        height: 22px;
        margin-right: 92px;
    }

    .grid {
        position: absolute;
        top: -9px;
        bottom: -9px;
        width: 1px;
        background: var(--grid);
    }

    .bar {
        position: absolute;
        top: 0;
        left: 0;
        height: 22px;
        padding: 0;
        border: 0;
        border-radius: 0 4px 4px 0;
        background: var(--bar);
        cursor: default;
        transition: filter 0.15s;
    }

    .bar.accent {
        background: var(--accent-bar);
    }

    .bar.lift {
        filter: brightness(1.12);
    }

    .value {
        position: absolute;
        top: 50%;
        transform: translateY(-50%);
        white-space: nowrap;
        font-size: 13px;
        font-variant-numeric: tabular-nums;
    }

    .p90 {
        margin-left: 8px;
        color: var(--text-3);
    }

    .axis .track {
        height: 22px;
    }

    .tick {
        position: absolute;
        top: 6px;
        transform: translateX(-50%);
        font-size: 11px;
        color: var(--text-3);
        font-variant-numeric: tabular-nums;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        font-size: 14px;
        font-variant-numeric: tabular-nums;
    }

    th,
    td {
        padding: 6px 8px;
        text-align: left;
        border-bottom: 1px solid var(--line);
        font-weight: 400;
    }

    thead th,
    .group th {
        font-weight: 600;
        color: var(--text-2);
        font-size: 13px;
    }

    td {
        text-align: right;
        white-space: nowrap;
    }

    thead th:not(:first-child) {
        text-align: right;
    }

    /* Narrow: names above their bars, fewer ticks. */
    @container (max-width: 560px) {
        .bar-row,
        .axis {
            grid-template-columns: 1fr;
            gap: 4px;
        }

        .bar-row {
            margin-bottom: 10px;
        }

        .axis .name {
            display: none;
        }

        .track {
            margin-right: 76px;
        }

        .tick:nth-child(even) {
            display: none;
        }
    }

    .toggle {
        margin-top: 12px;
        border: 0;
        background: none;
        padding: 0;
        color: var(--link);
        font-size: 13px;
        cursor: pointer;
    }
</style>
