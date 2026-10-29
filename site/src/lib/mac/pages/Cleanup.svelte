<script lang="ts">
    import ArrowRight from "@lucide/svelte/icons/arrow-right";
    import Card from "../Card.svelte";
    import DeviceButton from "../DeviceButton.svelte";
    import Divider from "../Divider.svelte";
    import Page from "../Page.svelte";
    import Row from "../Row.svelte";
    import SectionTitle from "../SectionTitle.svelte";
    import Switch from "../Switch.svelte";
    import { navigation, settings } from "../../settings.svelte";
    import { setCleanup } from "../../cleanup";

    const supported = $derived(settings.speechModel === "english");
    // Real outputs of the model for these transcripts (as in the app).
    const examples = [
        ["Can you send me the the report by, uh, tomorrow morning?", "Can you send me the report by tomorrow morning?"],
        ["Let's meet on Tuesday, no wait, Wednesday.", "Let's meet on Wednesday."],
        [
            "For the trip pack three things. First the charger, second the cable, and third the adapter.",
            "For the trip pack, three things:\n1. The charger\n2. The cable\n3. The adapter",
        ],
    ];
    const model = $derived(settings.cleanupModel);
</script>

<Page
    title="Cleanup"
    info="Cleanup uses [S1-mini by Superwhisper](https://huggingface.co/superwhisper/s1-mini/blob/main/LICENSE), a small language model trained for exactly this. It is downloaded once from Hugging Face (1.5 GB; 0.9 GB on disk), runs on this Mac like transcription, and adds about 25 ms."
>
    {#snippet trailing()}<DeviceButton />{/snippet}
    {#if !supported}
        <Card>
            <Row
                title="Cleanup works with the English speech model"
                subtitle="Its model was trained on English only. You're dictating with the multilingual model."
            >
                <button class="push" onclick={() => (navigation.page = "models")}>Models…</button>
            </Row>
        </Card>
    {/if}
    <Card>
        <Row title="Clean up transcripts" subtitle="Removes filler words, applies spoken corrections and formats lists">
            <Switch
                label="Clean up transcripts"
                checked={settings.cleanup && supported}
                disabled={!supported}
                onchange={(on) => setCleanup(on)}
            />
        </Row>
        {#if settings.cleanup || model.kind === "installed"}
            <Divider />
            {#if model.kind === "downloading"}
                <Row title="Downloading S1-mini by Superwhisper…" subtitle="{Math.round(model.fraction * 100)}% of 1.5 GB">
                    <span class="pair">
                        <progress value={model.fraction}></progress>
                        <button class="push" onclick={() => setCleanup(false)}>Cancel</button>
                    </span>
                </Row>
            {:else if model.kind === "preparing"}
                <Row title="Preparing S1-mini by Superwhisper…"><span class="spinner"></span></Row>
            {:else if model.kind === "installed"}
                <Row title="S1-mini by Superwhisper" subtitle="Installed · 915.1 MB">
                    <button
                        class="push"
                        onclick={() => {
                            setCleanup(false);
                            settings.cleanupModel = { kind: "absent" };
                        }}>Remove</button
                    >
                </Row>
            {:else}
                <Row title="S1-mini by Superwhisper" subtitle="1.5 GB download">
                    <button class="push" onclick={() => setCleanup(true)}>Download</button>
                </Row>
            {/if}
        {/if}
    </Card>

    <SectionTitle title="Examples" />
    <Card>
        {#each examples as [spoken, cleaned], i (i)}
            {#if i > 0}<Divider />{/if}
            <div class="example">
                <span class="secondary">{spoken}</span>
                <span class="arrow"><ArrowRight size={11} strokeWidth={2.6} /></span>
                <span class="cleaned">{cleaned}</span>
            </div>
        {/each}
    </Card>
</Page>

<style>
    .example {
        display: flex;
        align-items: flex-start;
        gap: 12px;
        padding: 11px 16px;
        font-size: 12.5px;
    }

    .example > span:first-child,
    .cleaned {
        flex: 1;
        white-space: pre-line;
    }

    .arrow {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        flex-shrink: 0;
        width: 22px;
        height: 22px;
        border-radius: 6px;
        background: var(--fill-2);
        color: var(--label-2);
    }

    .pair {
        display: flex;
        align-items: center;
        gap: 12px;
    }

    progress {
        width: 110px;
        height: 5px;
        -webkit-appearance: none;
        appearance: none;
        border: 0;
        border-radius: 3px;
        background: var(--fill-3);
        overflow: hidden;
    }

    progress::-webkit-progress-bar {
        background: var(--fill-3);
    }

    progress::-webkit-progress-value {
        background: var(--accent);
    }

    progress::-moz-progress-bar {
        background: var(--accent);
    }

    .spinner {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        border: 2px solid var(--fill-3);
        border-top-color: var(--label-2);
        animation: spin 0.8s linear infinite;
    }

    @keyframes spin {
        to {
            transform: rotate(360deg);
        }
    }
</style>
