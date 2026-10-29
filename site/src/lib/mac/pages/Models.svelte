<script lang="ts">
    import Trash from "@lucide/svelte/icons/trash";
    import Card from "../Card.svelte";
    import DeviceButton from "../DeviceButton.svelte";
    import Divider from "../Divider.svelte";
    import InfoButton from "../InfoButton.svelte";
    import Page from "../Page.svelte";
    import SectionTitle from "../SectionTitle.svelte";
    import { settings, type SpeechModel } from "../../settings.svelte";

    const languages =
        "Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish, French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese, Polish, Portuguese, Romanian, Russian, Slovak, Slovenian, Spanish, Swedish, and Ukrainian";
    const kinds: { kind: SpeechModel; name: string; badge: string; subtitle: string; size: string }[] = [
        {
            kind: "english",
            name: "English",
            badge: "EN",
            subtitle: "Parakeet Unified 0.6B · More accurate for English · Works with cleanup",
            size: "614.1 MB",
        },
        {
            kind: "multilingual",
            name: "Multilingual",
            badge: "25 languages",
            subtitle: "Parakeet v3 0.6B · 25 European languages · Cleanup isn't available",
            size: "483.3 MB",
        },
    ];
    const installedCount = $derived(Object.values(settings.models).filter((m) => m.kind === "installed").length);
    let timers: Partial<Record<SpeechModel, ReturnType<typeof setInterval>>> = {};

    /** Simulated: a few seconds for what takes a minute or so on a fast connection. */
    function download(kind: SpeechModel) {
        settings.models[kind] = { kind: "downloading", fraction: 0 };
        timers[kind] = setInterval(() => {
            const state = settings.models[kind];
            if (state.kind !== "downloading") return clearInterval(timers[kind]);
            const fraction = Math.min(1, state.fraction + 0.02 + Math.random() * 0.03);
            settings.models[kind] = fraction >= 1 ? { kind: "installed" } : { kind: "downloading", fraction };
            if (fraction >= 1) clearInterval(timers[kind]);
        }, 80);
    }

    function cancel(kind: SpeechModel) {
        clearInterval(timers[kind]);
        settings.models[kind] = { kind: "absent" };
    }

    function remove(kind: SpeechModel) {
        settings.models[kind] = { kind: "absent" };
        if (settings.speechModel === kind) settings.speechModel = kind === "english" ? "multilingual" : "english";
    }
</script>

<Page
    title="Models"
    info="Speech is transcribed on this Mac. Each model is downloaded once from Hugging Face; remove the ones you don't use to free space."
>
    {#snippet trailing()}<DeviceButton />{/snippet}
    <SectionTitle title="Speech models" first />
    <Card>
        {#each kinds as model, i (model.kind)}
            {@const state = settings.models[model.kind]}
            {#if i > 0}<Divider />{/if}
            <div class="model">
                <div class="text">
                    <div class="name">
                        <span>{model.name}</span>
                        <span class="badge">{model.badge}</span>
                        {#if model.kind === "multilingual"}
                            <InfoButton text="{languages}. It recognizes the language as you speak, so you can switch between them." />
                        {/if}
                    </div>
                    <div class="subtitle">{model.subtitle}</div>
                </div>
                <div class="control">
                    {#if state.kind === "installed"}
                        {#if settings.speechModel === model.kind}
                            <span class="in-use">In use</span>
                        {:else}
                            <button class="push" onclick={() => (settings.speechModel = model.kind)}>Use</button>
                        {/if}
                        <button
                            class="trash"
                            disabled={installedCount === 1}
                            title={installedCount === 1 ? "Localflow needs one speech model" : `Remove (${model.size})`}
                            aria-label="Remove the {model.name} model"
                            onclick={() => remove(model.kind)}
                        >
                            <Trash size={12} strokeWidth={1.8} />
                        </button>
                    {:else if state.kind === "downloading"}
                        <progress value={state.fraction}></progress>
                        <span class="percent">{Math.round(state.fraction * 100)}%</span>
                        <button class="push" onclick={() => cancel(model.kind)}>Cancel</button>
                    {:else}
                        <span class="in-use">{model.size}</span>
                        <button class="push" onclick={() => download(model.kind)}>Download</button>
                    {/if}
                </div>
            </div>
        {/each}
    </Card>
</Page>

<style>
    .model {
        display: flex;
        align-items: center;
        gap: 12px;
        min-height: 52px;
        padding: 10px 16px;
    }

    .text {
        flex: 1;
        display: flex;
        flex-direction: column;
        gap: 2px;
    }

    .name {
        display: flex;
        align-items: center;
        gap: 6px;
    }

    .badge {
        font-size: 9.5px;
        font-weight: 600;
        color: var(--label-2);
        padding: 2px 5px;
        border-radius: 4px;
        background: var(--fill-2);
    }

    .subtitle {
        font-size: 11px;
        color: var(--label-2);
    }

    .control {
        display: flex;
        align-items: center;
        gap: 10px;
    }

    .in-use,
    .percent {
        font-size: 12px;
        color: var(--label-2);
        font-variant-numeric: tabular-nums;
    }

    .trash {
        display: inline-flex;
        color: var(--label);
    }

    .trash:disabled {
        color: var(--label-3);
    }

    progress {
        width: 90px;
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
        border-radius: 3px;
    }

    progress::-moz-progress-bar {
        background: var(--accent);
    }
</style>
