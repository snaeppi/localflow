<script lang="ts">
    import BarChart from "./lib/BarChart.svelte";
    import Demo from "./lib/Demo.svelte";
    import { dictation } from "./lib/demo/dictation.svelte";
    import { charts, releaseToPaste } from "./lib/speed";

    const repo = "https://github.com/snaeppi/localflow";
    const icon = `${import.meta.env.BASE_URL}icon.png`;
    let demo = $state<HTMLElement>();
    let copied = $state(false);
    const install = `git clone ${repo}.git
cd localflow
scripts/build-app.sh --install`;

    // The demo plays by itself while it's on screen, until the visitor takes over; it stops while it's
    // scrolled away or the tab is hidden.
    $effect(() => {
        if (!demo) return;
        let visible = false;
        const update = () => {
            if (visible && !document.hidden && !dictation.touched && !dictation.autoplay && dictation.phase === "idle") {
                dictation.playAll();
            } else if (!visible || document.hidden) {
                dictation.halt();
            }
        };
        const observer = new IntersectionObserver(
            ([entry]) => {
                visible = entry.isIntersecting;
                update();
            },
            { threshold: 0.6 },
        );
        observer.observe(demo);
        document.addEventListener("visibilitychange", update);
        return () => {
            observer.disconnect();
            document.removeEventListener("visibilitychange", update);
        };
    });

    async function copy() {
        await navigator.clipboard.writeText(install);
        copied = true;
        setTimeout(() => (copied = false), 1500);
    }
</script>

{#snippet github(size: number)}
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
        <path
            fill="currentColor"
            d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"
        />
    </svg>
{/snippet}

<header class="top">
    <a class="brand" href="#top"><img src={icon} alt="" width="28" height="28" />Localflow</a>
    <nav>
        <a href="#demo">Demo</a>
        <a href="#speed">Speed</a>
        <a href="#install">Install</a>
        <a class="gh" href={repo} aria-label="Source on GitHub">{@render github(18)}</a>
    </nav>
</header>

<main id="top">
    <section class="hero">
        <img class="icon" src={icon} alt="" width="96" height="96" />
        <h1>Localflow</h1>
        <p class="lede">Dictation for the Mac menu bar. Hold a key, speak, release, and the text is pasted at the cursor.</p>
        <p class="sub">
            Speech is transcribed on your Mac with NVIDIA's Parakeet models, in English or in 25 European languages, and
            a small optional model cleans up the transcript. Your audio and text never leave the Mac. For Apple Silicon and
            macOS 26; open source under Apache 2.0.
        </p>
        <div class="actions">
            <a class="button primary" href={repo}>{@render github(16)} Source on GitHub</a>
            <a class="button" href="#install">Build and install</a>
        </div>
    </section>

    <section id="demo" class="demo-section" bind:this={demo}>
        <Demo />
    </section>

    <section class="features">
        <div class="feature">
            <h3>Hold to talk, tap for hands-free</h3>
            <p>
                Hold Right ⌘, speak, release. A short tap keeps listening until the next one, and Esc cancels. Right ⌘ is
                still your Command key: Right ⌘ + C copies and drops the dictation. Any right-hand modifier, key combination
                or mouse button can be the shortcut.
            </p>
        </div>
        <div class="feature">
            <h3>Pasted where you type</h3>
            <p>
                In native, web and Electron apps and in terminals, at any length, with the app's own undo. Your clipboard is
                put back a second later, and clipboard managers skip the dictation.
            </p>
        </div>
        <div class="feature">
            <h3>Cleanup, if you want it</h3>
            <p>
                S1-mini by Superwhisper removes "um"s and stutters, applies spoken corrections ("Tuesday, no wait,
                Wednesday"), fixes punctuation and formats spoken lists, without rewording or answering what you dictate.
                About 25 ms, on the CPU. English only.
            </p>
        </div>
        <div class="feature">
            <h3>Your vocabulary</h3>
            <p>
                Names, products and jargon are spelled your way ("fluid audio" → FluidAudio), and replacements swap a
                phrase for exact text. Fix a misheard name right after dictating and Localflow adds it for next time.
            </p>
        </div>
        <div class="feature">
            <h3>English or 25 European languages</h3>
            <p>
                Parakeet Unified 0.6B for English: on dictation-style speech it tied the most accurate model tested, at a
                third of its latency. Parakeet v3 0.6B for Bulgarian to Ukrainian, recognizing the language as you speak.
            </p>
        </div>
        <div class="feature">
            <h3>Offline and private</h3>
            <p>
                The models are downloaded once from Hugging Face, from pinned revisions checked against their SHA-256
                sums. Nothing else uses the network: no accounts, telemetry or history, and the log has timings only.
            </p>
        </div>
    </section>

    <section id="speed" class="speed">
        <h2>Speed</h2>
        <p class="section-lede">
            Localflow runs the speech models' decoders and the cleanup model on its own C code instead of the usual
            libraries, and the cleanup model uses the SME matrix units of M4 and newer chips. Measured on an M4 Pro
            (macOS 27.0) in October 2026, with a second of idle before each dictation as between real ones; methods and
            commands are in <a href="{repo}/blob/main/bench/README.md">bench/README.md</a>.
        </p>
        <div class="stats">
            <div class="stat">
                <span class="figure">{releaseToPaste.plain} ms</span>
                <span class="label">from key release to the text pasted, median of {releaseToPaste.dictations} dictations</span>
            </div>
            <div class="stat">
                <span class="figure">{releaseToPaste.cleanup} ms</span>
                <span class="label">the same with cleanup</span>
            </div>
        </div>
        <div class="charts">
            {#each charts as chart (chart.title)}
                <BarChart {chart} />
            {/each}
        </div>
    </section>

    <section id="install" class="install">
        <h2>Build and install</h2>
        <p>Requires an Apple Silicon Mac with macOS 26 or later and Xcode 26.</p>
        <div class="code">
            <pre>{install}</pre>
            <button onclick={copy}>{copied ? "Copied" : "Copy"}</button>
        </div>
        <p>
            The build signs the app with a local identity, so macOS keeps its permissions across rebuilds. On first launch a
            short walkthrough lets you choose the speech model (English, 0.6 GB, or multilingual, 0.5 GB), which downloads
            while you grant Microphone and Accessibility access and try a dictation.
        </p>
    </section>
</main>

<footer>
    <p>
        Localflow is open source under Apache 2.0. The models keep their own licenses: NVIDIA's Parakeet models are CC BY
        4.0, S1-mini by Superwhisper is Apache 2.0.
    </p>
    <p><a href={repo}>github.com/snaeppi/localflow</a></p>
</footer>

<style>
    .top {
        position: sticky;
        top: 0;
        z-index: 100;
        display: flex;
        align-items: center;
        justify-content: space-between;
        max-width: 1180px;
        margin: 0 auto;
        padding: 14px 24px;
        background: color-mix(in srgb, var(--bg) 82%, transparent);
        -webkit-backdrop-filter: blur(14px);
        backdrop-filter: blur(14px);
    }

    .brand {
        display: flex;
        align-items: center;
        gap: 10px;
        color: var(--text);
        font-weight: 600;
        font-size: 17px;
        text-decoration: none !important;
    }

    .brand img {
        border-radius: 7px;
    }

    nav {
        display: flex;
        align-items: center;
        gap: 22px;
        font-size: 15px;
    }

    nav a {
        color: var(--text-2);
    }

    .gh {
        display: inline-flex;
        color: var(--text);
    }

    main {
        max-width: 1180px;
        margin: 0 auto;
        padding: 0 24px;
    }

    .hero {
        display: flex;
        flex-direction: column;
        align-items: center;
        text-align: center;
        padding: 56px 0 40px;
    }

    .icon {
        filter: drop-shadow(0 10px 24px rgb(0 0 0 / 0.18));
    }

    h1 {
        margin: 18px 0 8px;
        font-size: clamp(44px, 7vw, 72px);
        font-weight: 700;
        letter-spacing: -0.035em;
        line-height: 1;
    }

    .lede {
        max-width: 640px;
        margin: 10px 0 0;
        font-size: clamp(19px, 2.4vw, 24px);
        line-height: 1.35;
        letter-spacing: -0.01em;
    }

    .sub {
        max-width: 640px;
        margin: 16px 0 0;
        color: var(--text-2);
        font-size: 16px;
    }

    .actions {
        display: flex;
        gap: 12px;
        margin-top: 28px;
        flex-wrap: wrap;
        justify-content: center;
    }

    .button {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        padding: 10px 18px;
        border-radius: 999px;
        border: 1px solid var(--line);
        background: var(--surface);
        color: var(--text);
        font-size: 15px;
        font-weight: 500;
        text-decoration: none !important;
    }

    .button.primary {
        background: var(--text);
        border-color: var(--text);
        color: var(--bg);
    }

    .demo-section {
        padding: 12px 0 72px;
        scroll-margin-top: 64px;
    }

    .features {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
        gap: 36px 40px;
        padding: 56px 0 72px;
        border-top: 1px solid var(--line);
    }

    .feature h3 {
        margin: 0 0 8px;
        font-size: 18px;
        font-weight: 600;
        letter-spacing: -0.01em;
    }

    .feature p {
        margin: 0;
        color: var(--text-2);
    }

    h2 {
        margin: 0 0 12px;
        font-size: 34px;
        font-weight: 700;
        letter-spacing: -0.025em;
    }

    .speed,
    .install {
        padding: 64px 0 72px;
        border-top: 1px solid var(--line);
        scroll-margin-top: 64px;
    }

    .section-lede {
        max-width: 760px;
        margin: 0 0 32px;
        color: var(--text-2);
    }

    .stats {
        display: flex;
        gap: 48px;
        flex-wrap: wrap;
        margin-bottom: 36px;
    }

    .stat {
        display: flex;
        flex-direction: column;
        max-width: 260px;
    }

    .figure {
        font-size: 52px;
        font-weight: 600;
        letter-spacing: -0.03em;
        line-height: 1.1;
    }

    .stat .label {
        color: var(--text-2);
        font-size: 15px;
    }

    .charts {
        display: grid;
        gap: 24px;
    }

    .install p {
        max-width: 760px;
        color: var(--text-2);
    }

    .code {
        position: relative;
        max-width: 760px;
        margin: 18px 0;
        border-radius: 12px;
        background: var(--code-bg);
        box-shadow: 0 0 0 1px var(--line);
    }

    pre {
        margin: 0;
        padding: 16px 76px 16px 18px;
        font-family: var(--mono);
        font-size: 14px;
        line-height: 1.6;
        overflow-x: auto;
    }

    .code button {
        position: absolute;
        top: 10px;
        right: 10px;
        border: 1px solid var(--line);
        border-radius: 8px;
        padding: 3px 10px;
        background: var(--surface);
        font-size: 13px;
        cursor: pointer;
    }

    footer {
        max-width: 1180px;
        margin: 0 auto;
        padding: 32px 24px 56px;
        border-top: 1px solid var(--line);
        color: var(--text-3);
        font-size: 14px;
    }

    footer p {
        margin: 0 0 6px;
    }
</style>
