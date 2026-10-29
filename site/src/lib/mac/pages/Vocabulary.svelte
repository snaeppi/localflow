<script lang="ts">
    // Words and replacements (VocabularyView.swift): one field that adds a word (⏎), opens a "Replace with…"
    // box (⌘⏎) and searches the list as you type; one alphabetical list with a delete button on hover.
    import ArrowRight from "@lucide/svelte/icons/arrow-right";
    import ChevronLeft from "@lucide/svelte/icons/chevron-left";
    import CircleArrowDown from "@lucide/svelte/icons/circle-arrow-down";
    import FileDown from "@lucide/svelte/icons/file-down";
    import FileText from "@lucide/svelte/icons/file-text";
    import X from "@lucide/svelte/icons/x";
    import GlassIconButton from "../GlassIconButton.svelte";
    import InfoButton from "../InfoButton.svelte";
    import KeyCap from "../KeyCap.svelte";
    import Page from "../Page.svelte";
    import Switch from "../Switch.svelte";
    import { settings, type Replacement } from "../../settings.svelte";

    type Item = { kind: "word"; word: string } | { kind: "replacement"; entry: Replacement };

    let entry = $state("");
    let replacement = $state("");
    let replacing = $state(false);
    let editing = $state<number | null>(null);
    let importing = $state(false);
    let hoveringImport = $state(false);
    let notice = $state<string | null>(null);
    let entryField = $state<HTMLInputElement>();
    let replacementField = $state<HTMLTextAreaElement>();
    let fileInput = $state<HTMLInputElement>();

    const query = $derived(entry.trim());
    const search = $derived(replacing ? "" : query);
    const contains = (text: string) => text.toLowerCase().includes(search.toLowerCase());
    const items = $derived(
        [
            ...settings.words.map((word): Item => ({ kind: "word", word })),
            ...settings.replacements.map((entry): Item => ({ kind: "replacement", entry })),
        ]
            .filter((i) => !search || (i.kind === "word" ? contains(i.word) : contains(i.entry.original) || contains(i.entry.replacement)))
            .sort((a, b) =>
                (a.kind === "word" ? a.word : a.entry.original).localeCompare(b.kind === "word" ? b.word : b.entry.original, undefined, {
                    sensitivity: "base",
                    numeric: true,
                }),
            ),
    );

    $effect(() => {
        const t = setTimeout(() => entryField?.focus({ preventScroll: true }), 150);
        return () => clearTimeout(t);
    });

    function addWord() {
        if (!query) return;
        if (!settings.words.some((w) => w.toLowerCase() === query.toLowerCase())) settings.words.push(query);
        entry = "";
    }

    function openReplacement() {
        if (!query) return;
        replacing = true;
        setTimeout(() => replacementField?.focus());
    }

    function saveReplacement() {
        const text = replacement.trim();
        if (!query || !text) return;
        const existing = settings.replacements.find((r) =>
            editing !== null ? r.id === editing : r.original.toLowerCase() === query.toLowerCase(),
        );
        if (existing) {
            existing.original = query;
            existing.replacement = text;
        } else {
            settings.replacements.push({ id: Date.now(), original: query, replacement: text });
        }
        entry = "";
        closeReplacement();
    }

    function closeReplacement() {
        if (editing !== null) entry = "";
        editing = null;
        replacement = "";
        replacing = false;
        entryField?.focus();
    }

    function edit(item: Replacement) {
        editing = item.id;
        entry = item.original;
        replacement = item.replacement;
        replacing = true;
        setTimeout(() => replacementField?.focus());
    }

    function remove(item: Item) {
        if (item.kind === "word") settings.words = settings.words.filter((w) => w !== item.word);
        else {
            settings.replacements = settings.replacements.filter((r) => r.id !== item.entry.id);
            if (item.entry.id === editing) closeReplacement();
        }
    }

    function keydown(event: KeyboardEvent) {
        if (event.key === "Enter" && event.metaKey) {
            event.preventDefault();
            if (replacing) saveReplacement();
            else openReplacement();
        } else if (event.key === "Enter" && event.currentTarget === entryField) {
            event.preventDefault();
            if (replacing) replacementField?.focus();
            else addWord();
        } else if (event.key === "Escape") {
            if (replacing) closeReplacement();
            else entry = "";
        }
    }

    /** A CSV file with a `word` column and an optional `replacement` column, as the app imports. */
    async function importFile(file: File | undefined) {
        importing = false;
        if (!file) return;
        if (!file.name.toLowerCase().endsWith(".csv")) {
            notice = `Only .csv files can be imported. Localflow can’t read “${file.name}”.`;
            return;
        }
        const rows = (await file.text())
            .replace(/^\uFEFF/, "")
            .split(/\r?\n/)
            .filter((l) => l.trim())
            .map((l) => l.split(l.includes(";") && !l.includes(",") ? ";" : ",").map((c) => c.trim().replace(/^"|"$/g, "")));
        const header = rows.shift()?.map((h) => h.toLowerCase()) ?? [];
        const wordColumn = header.indexOf("word");
        const replacementColumn = header.indexOf("replacement");
        if (wordColumn < 0) {
            notice = "The CSV must include a “word” column.";
            return;
        }
        let added = 0;
        for (const row of rows) {
            const word = row[wordColumn];
            const repl = replacementColumn >= 0 ? row[replacementColumn] : "";
            if (!word) continue;
            if (repl) {
                if (!settings.replacements.some((r) => r.original.toLowerCase() === word.toLowerCase())) {
                    settings.replacements.push({ id: Date.now() + added, original: word, replacement: repl });
                    added++;
                }
            } else if (!settings.words.some((w) => w.toLowerCase() === word.toLowerCase())) {
                settings.words.push(word);
                added++;
            }
        }
        notice = added === 0 ? "Everything in the file is already in your vocabulary." : `Imported ${added} item${added === 1 ? "" : "s"}`;
    }

    function saveExample() {
        const blob = new Blob(["word,replacement\nKubernetes,\nNiamh,\nmy email,me@example.com\n"], { type: "text/csv" });
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "localflow-vocabulary-example.csv";
        a.click();
        URL.revokeObjectURL(a.href);
    }

    /** The text with the search match marked. */
    function parts(text: string) {
        const i = search ? text.toLowerCase().indexOf(search.toLowerCase()) : -1;
        return i < 0 ? [text, "", ""] : [text.slice(0, i), text.slice(i, i + search.length), text.slice(i + search.length)];
    }
</script>

{#snippet marked(text: string)}
    {@const [before, match, after] = parts(text)}{before}{#if match}<mark>{match}</mark>{/if}{after}
{/snippet}

<div class="vocabulary" class:importing>
    <Page
        wide
        title="Vocabulary"
        info={"Words help Localflow spell names, acronyms and jargon. Replacements swap a word or phrase for your exact text after every dictation.\n\nType to search the list. ⏎ adds a word, ⌘⏎ a replacement. Import a CSV file with a “word” column and an optional “replacement” column."}
    >
        {#snippet trailing()}
            <span class="import-button">
                <span class="import-name" class:visible={hoveringImport}>Import CSV</span>
                <GlassIconButton label="Import CSV" onclick={() => (importing = true)} onhover={(h) => (hoveringImport = h)}>
                    <FileDown size={14} strokeWidth={1.8} />
                </GlassIconButton>
            </span>
        {/snippet}
        {#snippet bottom()}
            <div class="learn">
                <span>Learn from corrections</span>
                <InfoButton
                    text="When you fix a misheard name or term right after dictating, Localflow adds it here. It reads the text field you dictated into for 30 seconds and keeps only the corrected word."
                />
                <span class="spacer"></span>
                <Switch label="Learn from corrections" bind:checked={settings.learnCorrections} />
            </div>
        {/snippet}
        <div class="fields">
            <div class="entry field">
                <input
                    bind:this={entryField}
                    bind:value={entry}
                    placeholder="New word or replacement"
                    aria-label="New word or replacement"
                    onkeydown={keydown}
                />
                {#if !replacing}
                    <button class="hint" disabled={!query} onclick={addWord}>Add word <KeyCap key="⏎" /></button>
                    <button class="hint" disabled={!query} onclick={openReplacement}
                        >Replace with… <span class="caps"><KeyCap key="⌘" /><KeyCap key="⏎" /></span></button
                    >
                {/if}
            </div>
            {#if replacing}
                <div class="replacement field">
                    <textarea bind:this={replacementField} bind:value={replacement} placeholder="Replace with…" onkeydown={keydown}></textarea>
                    <button class="hint" disabled={!query || !replacement.trim()} onclick={saveReplacement}>
                        {editing === null ? "Add replacement" : "Save replacement"}
                        <span class="caps"><KeyCap key="⌘" /><KeyCap key="⏎" /></span>
                    </button>
                </div>
            {/if}
        </div>
        <div class="list">
            {#if items.length === 0}
                <div class="empty">{search ? `Nothing matches “${search}”` : "No words or replacements yet"}</div>
            {/if}
            {#each items as item (item.kind === "word" ? `w ${item.word}` : item.entry.id)}
                <div
                    class="item"
                    role="button"
                    tabindex="-1"
                    onclick={() => item.kind === "replacement" && edit(item.entry)}
                    onkeydown={() => {}}
                >
                    {#if item.kind === "word"}
                        <span class="word">{@render marked(item.word)}</span>
                    {:else}
                        <span class="original">{@render marked(item.entry.original)}</span>
                        <span class="arrow"><ArrowRight size={11} strokeWidth={2.6} /></span>
                        <span class="word">{@render marked(item.entry.replacement.replaceAll("\n", " "))}</span>
                    {/if}
                    <button
                        class="delete"
                        title="Delete"
                        aria-label="Delete"
                        onclick={(e) => {
                            e.stopPropagation();
                            remove(item);
                        }}><X size={12} strokeWidth={2} /></button
                    >
                </div>
            {/each}
        </div>
    </Page>

    {#if importing}
        <div class="shade" role="presentation" onclick={() => (importing = false)}></div>
        <div class="import">
            <div class="import-header">
                <button class="back" aria-label="Back" onclick={() => (importing = false)}><ChevronLeft size={15} strokeWidth={2.2} /></button>
                <span>Import vocabulary</span>
            </div>
            <button
                class="drop"
                onclick={() => fileInput?.click()}
                ondragover={(e) => e.preventDefault()}
                ondrop={(e) => {
                    e.preventDefault();
                    importFile(e.dataTransfer?.files[0]);
                }}
            >
                <FileText size={18} strokeWidth={1.6} />
                <span class="drop-title">Import CSV</span>
                <span class="secondary">Drag and drop or select file</span>
            </button>
            <div class="import-foot">
                <button class="secondary example" onclick={saveExample}><CircleArrowDown size={11} strokeWidth={2} /> Example file</button>
                <span class="secondary"><code>word</code> and <code>replacement</code> headers required</span>
            </div>
            <input bind:this={fileInput} type="file" accept=".csv,text/csv" hidden onchange={(e) => importFile(e.currentTarget.files?.[0])} />
        </div>
    {/if}

    {#if notice}
        <div class="alert" role="alertdialog">
            <p>{notice}</p>
            <button class="push" onclick={() => (notice = null)}>OK</button>
        </div>
    {/if}
</div>

<style>
    .vocabulary {
        position: relative;
        height: 100%;
    }

    .import-button {
        display: flex;
        align-items: center;
        gap: 10px;
    }

    .import-name {
        font-size: 12px;
        font-weight: 500;
        color: var(--label-2);
        opacity: 0;
        transition: opacity 0.15s;
    }

    .import-name.visible {
        opacity: 1;
    }

    .fields {
        display: flex;
        flex-direction: column;
        gap: 10px;
        padding: 0 24px 8px;
    }

    .field {
        border-radius: 12px;
        background: var(--field);
        box-shadow: inset 0 0 0 1px var(--fill-3);
    }

    .entry {
        display: flex;
        align-items: center;
        gap: 16px;
        height: 36px;
        padding: 0 16px;
    }

    input,
    textarea {
        flex: 1;
        min-width: 0;
        border: 0;
        outline: none;
        background: none;
        padding: 0;
        font-size: 13px;
    }

    input::placeholder,
    textarea::placeholder {
        color: var(--label-3);
    }

    .replacement {
        display: flex;
        flex-direction: column;
        align-items: flex-end;
        gap: 4px;
        padding: 10px 10px 10px 16px;
    }

    textarea {
        width: 100%;
        height: 60px;
        resize: none;
    }

    .hint {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        color: var(--label-2);
        white-space: nowrap;
    }

    .hint:disabled {
        opacity: 0.6;
    }

    .caps {
        display: inline-flex;
        gap: 3px;
    }

    .list {
        padding: 0 24px 12px;
    }

    .empty {
        padding-top: 24px;
        text-align: center;
        color: var(--label-2);
    }

    .item {
        display: flex;
        align-items: center;
        height: 36px;
        padding: 0 16px;
        border-radius: 10px;
        white-space: nowrap;
    }

    .item:hover {
        background: var(--fill);
    }

    .original {
        width: 150px;
        overflow: hidden;
        text-overflow: ellipsis;
    }

    .word {
        flex: 1;
        overflow: hidden;
        text-overflow: ellipsis;
    }

    .original + .arrow + .word {
        flex: 1;
    }

    .arrow {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 20px;
        height: 20px;
        margin-right: 8px;
        border-radius: 5px;
        background: var(--fill-2);
        color: var(--label-2);
    }

    .delete {
        display: none;
        align-items: center;
        justify-content: center;
        width: 24px;
        height: 24px;
        color: var(--label-2);
    }

    .item:hover .delete {
        display: inline-flex;
    }

    mark {
        background: color-mix(in srgb, var(--accent) 25%, transparent);
        color: inherit;
        border-radius: 2px;
    }

    .learn {
        display: flex;
        align-items: center;
        gap: 6px;
        height: 45px;
        padding: 0 16px;
        border-radius: 18px;
        background: var(--card);
        box-shadow:
            inset 0 0 0 0.5px var(--card-edge),
            inset 0 1px 0 var(--card-shine),
            var(--card-shadow);
    }

    .spacer {
        flex: 1;
    }

    .importing :global(.page) {
        opacity: 0.6;
    }

    .shade {
        position: absolute;
        inset: 0;
    }

    .import {
        position: absolute;
        top: 0;
        right: 0;
        bottom: 0;
        width: 345px;
        display: flex;
        flex-direction: column;
        background: var(--window-page);
        box-shadow: inset 1px 0 0 var(--fill-3);
        animation: slide 0.2s ease-out;
    }

    @keyframes slide {
        from {
            transform: translateX(100%);
        }
    }

    .import-header {
        position: relative;
        display: flex;
        align-items: center;
        justify-content: center;
        height: 48px;
        font-weight: 600;
    }

    .back {
        position: absolute;
        left: 8px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 28px;
        height: 28px;
        color: var(--label-2);
    }

    .drop {
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 4px;
        min-height: 107px;
        margin: 20px 16px 0;
        border-radius: 12px;
        border: 1px dashed var(--fill-3) !important;
        color: var(--label-2);
    }

    .drop-title {
        margin-top: 4px;
        color: var(--label);
        opacity: 0.8;
    }

    .import-foot {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 10px 16px 0;
        font-size: 11px;
    }

    .example {
        display: inline-flex;
        align-items: center;
        gap: 4px;
    }

    code {
        font-family: var(--mono);
        font-size: 11px;
        background: none;
        padding: 0;
        color: var(--label);
    }

    .alert {
        position: absolute;
        top: 60px;
        left: 50%;
        transform: translateX(-50%);
        width: 260px;
        padding: 18px;
        border-radius: 16px;
        background: var(--menu);
        -webkit-backdrop-filter: blur(30px);
        backdrop-filter: blur(30px);
        box-shadow:
            0 0 0 0.5px var(--window-edge),
            0 12px 40px rgb(0 0 0 / 0.25);
        display: flex;
        flex-direction: column;
        gap: 12px;
    }

    .alert p {
        margin: 0;
    }

    .alert .push {
        align-self: stretch;
        background: var(--accent);
        color: #fff;
    }
</style>
