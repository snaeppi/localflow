<script lang="ts">
    // A theme thumbnail in the style of System Settings › Appearance (the app shows macOS's own; these are
    // drawn): wallpaper, a window with traffic lights; Auto is half light, half dark.
    let { theme, selected }: { theme: "auto" | "light" | "dark"; selected: boolean } = $props();
    const id = $props.id();
</script>

{#snippet scene(dark: boolean)}
    <rect width="67" height="44" fill="url(#{id}-{dark ? 'dark' : 'light'})" />
    <path
        d="M-6 30 C 14 12, 30 40, 52 16 S 70 4, 76 2"
        fill="none"
        stroke={dark ? "#4b46d6" : "#ffffff"}
        stroke-opacity={dark ? 0.55 : 0.5}
        stroke-width="7"
    />
    <rect x="0" y="0" width="67" height="3.5" fill={dark ? "#000" : "#fff"} fill-opacity={dark ? 0.35 : 0.45} />
    <rect x="5" y="8" width="33" height="10" rx="2.5" fill={dark ? "#24247a" : "#b9d1f6"} />
    <rect x="25" y="22" width="40" height="22" rx="4" fill={dark ? "#111214" : "#f6f6f6"} />
    <circle cx="31" cy="31.5" r="1.8" fill="#ec6a5e" />
    <circle cx="36.5" cy="31.5" r="1.8" fill="#f4bf4f" />
    <circle cx="42" cy="31.5" r="1.8" fill="#61c554" />
{/snippet}

<span class="tile" class:selected>
    <svg width="67" height="44" viewBox="0 0 67 44" aria-hidden="true">
        <defs>
            <linearGradient id="{id}-light" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0" stop-color="#c9dcf8" />
                <stop offset="0.55" stop-color="#5b8ef0" />
                <stop offset="1" stop-color="#2f4fd0" />
            </linearGradient>
            <linearGradient id="{id}-dark" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0" stop-color="#2b2f9c" />
                <stop offset="0.6" stop-color="#151a5e" />
                <stop offset="1" stop-color="#070a26" />
            </linearGradient>
            <clipPath id="{id}-right"><rect x="33.5" y="0" width="34" height="44" /></clipPath>
        </defs>
        {@render scene(theme === "dark")}
        {#if theme === "auto"}
            <g clip-path="url(#{id}-right)">{@render scene(true)}</g>
        {/if}
    </svg>
</span>

<style>
    .tile {
        display: block;
        padding: 2.5px;
        border-radius: 10.5px;
        box-shadow: inset 0 0 0 2px transparent;
    }

    .tile.selected {
        box-shadow: inset 0 0 0 2px var(--accent);
    }

    svg {
        display: block;
        border-radius: 8px;
        box-shadow: inset 0 0 0 1px rgb(0 0 0 / 0.3);
        outline: 1px solid rgb(0 0 0 / 0.3);
        outline-offset: -1px;
    }
</style>
