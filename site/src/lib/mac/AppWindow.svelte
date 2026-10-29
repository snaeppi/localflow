<script lang="ts">
    // The app a scene dictates into: a plain stand-in for a chat, mail, notes or code editor window, with
    // the text field the dictation is pasted into.
    import type { AppKind } from "../demo/clips";
    import { dictation } from "../demo/dictation.svelte";

    let { app, sceneId, french = false }: { app: AppKind; sceneId: string; french?: boolean } = $props();
    const text = $derived(dictation.texts[sceneId] ?? "");
    const caret = $derived(dictation.phase !== "finishing");
</script>

{#snippet field(placeholder: string)}
    <span class="typed">{text}</span>{#if caret}<span class="caret"></span>{/if}{#if !text}<span class="placeholder">{placeholder}</span>{/if}
{/snippet}

<div class="window {app}">
    <div class="titlebar">
        <span class="lights"><i></i><i></i><i></i></span>
        <span class="title">
            {#if app === "messages"}Sam Rivera{:else if app === "mail"}Pricing page{:else if app === "notes"}{french ? "Réunion" : "Monday"}{:else}api — fetchUserProfile.ts{/if}
        </span>
    </div>

    {#if app === "messages"}
        <div class="body">
            <aside class="list">
                <div class="conversation selected"><b>Sam Rivera</b><span>Are we still on for tomorrow?</span></div>
                <div class="conversation"><b>Maya</b><span>Sent the spec 👍</span></div>
                <div class="conversation"><b>Tomas</b><span>Room's booked</span></div>
            </aside>
            <section class="chat">
                <div class="bubbles">
                    <span class="bubble in">Are we still on for tomorrow?</span>
                    <span class="bubble in">Where should we meet?</span>
                    {#each dictation.sent as message, i (i)}<span class="bubble out">{message}</span>{/each}
                </div>
                <div class="compose">{@render field("Message")}</div>
            </section>
        </div>
    {:else if app === "mail"}
        <div class="mail-body">
            <div class="header-row"><span>To:</span><span class="token">Jordan Lee</span></div>
            <div class="header-row"><span>Subject:</span>Pricing page</div>
            <div class="text-area">{@render field("")}</div>
        </div>
    {:else if app === "notes"}
        <div class="body">
            <aside class="list notes-list">
                <div class="conversation selected"><b>{french ? "Réunion" : "Monday"}</b><span>{french ? "Aujourd'hui" : "Today"}</span></div>
                <div class="conversation"><b>{french ? "Courses" : "Groceries"}</b><span>{french ? "Hier" : "Yesterday"}</span></div>
                <div class="conversation"><b>{french ? "Idées" : "Ideas"}</b><span>{french ? "Lundi" : "Last week"}</span></div>
            </aside>
            <section class="note">
                <h4>{french ? "Réunion" : "Monday"}</h4>
                <div class="text-area">{@render field("")}</div>
            </section>
        </div>
    {:else}
        <div class="body">
            <aside class="list files">
                <div>▾ src</div>
                <div class="file selected">fetchUserProfile.ts</div>
                <div class="file">config.ts</div>
                <div class="file">session.ts</div>
            </aside>
            <pre class="code"><span class="k">import</span> {"{"} config {"}"} <span class="k">from</span> <span class="s">"./config"</span>;

<span class="k">export async function</span> <span class="f">fetchUserProfile</span>(id: <span class="t">string</span>) {"{"}
    <span class="k">for</span> (<span class="k">let</span> attempt = 0; attempt &lt; <span class="n">3</span>; attempt++) {"{"}
        <span class="k">const</span> res = <span class="k">await</span> fetch(<span class="s">`/api/users/${"{"}id{"}"}`</span>);
        <span class="k">if</span> (res.ok) <span class="k">return</span> res.json();
    {"}"}
    <span class="k">throw new</span> Error(<span class="s">"profile unavailable"</span>);
{"}"}</pre>
            <section class="assistant">
                <div class="assistant-title">Assistant</div>
                <div class="assistant-hint">Ask about this file</div>
                <div class="compose">{@render field("Ask anything")}</div>
            </section>
        </div>
    {/if}
</div>

<style>
    .window {
        display: flex;
        flex-direction: column;
        border-radius: 16px;
        overflow: hidden;
        background: var(--app-bg);
        box-shadow:
            0 0 0 0.5px var(--window-edge),
            0 22px 70px rgb(0 0 0 / 0.3),
            0 4px 14px rgb(0 0 0 / 0.1);
        color: var(--label);
    }

    .messages {
        width: 600px;
        height: 380px;
    }

    .mail {
        width: 560px;
        height: 380px;
    }

    .notes {
        width: 620px;
        height: 380px;
    }

    .editor {
        width: 800px;
        height: 400px;
    }

    .titlebar {
        position: relative;
        display: flex;
        align-items: center;
        justify-content: center;
        height: 40px;
        flex-shrink: 0;
        border-bottom: 1px solid var(--fill-2);
        font-weight: 600;
    }

    .lights {
        position: absolute;
        left: 14px;
        display: flex;
        gap: 8px;
    }

    .lights i {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #ff5f57;
    }

    .lights i:nth-child(2) {
        background: #febc2e;
    }

    .lights i:nth-child(3) {
        background: #28c840;
    }

    .body {
        display: flex;
        flex: 1;
        min-height: 0;
    }

    .list {
        width: 190px;
        flex-shrink: 0;
        padding: 8px;
        background: var(--fill);
        border-right: 1px solid var(--fill-2);
        display: flex;
        flex-direction: column;
        gap: 2px;
    }

    .conversation {
        display: flex;
        flex-direction: column;
        padding: 7px 10px;
        border-radius: 8px;
        font-size: 12px;
    }

    .conversation span {
        color: var(--label-2);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
    }

    .conversation.selected {
        background: var(--fill-3);
    }

    .chat {
        flex: 1;
        display: flex;
        flex-direction: column;
        padding: 14px;
        min-width: 0;
    }

    .bubbles {
        flex: 1;
        display: flex;
        flex-direction: column;
        justify-content: flex-end;
        gap: 6px;
        overflow: hidden;
    }

    .bubble {
        max-width: 78%;
        padding: 7px 12px;
        border-radius: 17px;
        line-height: 1.3;
        white-space: pre-wrap;
    }

    .bubble.in {
        align-self: flex-start;
        background: var(--fill-3);
    }

    .bubble.out {
        align-self: flex-end;
        background: #0a84ff;
        color: #fff;
        animation: send 0.25s ease-out;
    }

    @keyframes send {
        from {
            transform: translateY(16px);
            opacity: 0;
        }
    }

    .compose {
        margin-top: 12px;
        min-height: 30px;
        padding: 6px 12px;
        border-radius: 15px;
        box-shadow: inset 0 0 0 1px var(--fill-3);
        line-height: 1.35;
        white-space: pre-wrap;
    }

    .mail-body {
        flex: 1;
        display: flex;
        flex-direction: column;
        padding: 0 18px;
    }

    .header-row {
        display: flex;
        gap: 8px;
        align-items: center;
        min-height: 34px;
        border-bottom: 1px solid var(--fill-2);
    }

    .header-row span:first-child {
        color: var(--label-2);
    }

    .token {
        padding: 1px 8px;
        border-radius: 10px;
        background: color-mix(in srgb, #0a84ff 18%, transparent);
        color: #0a84ff;
    }

    .text-area {
        flex: 1;
        padding: 14px 0;
        white-space: pre-wrap;
        line-height: 1.45;
    }

    .note {
        flex: 1;
        padding: 16px 22px;
        min-width: 0;
        display: flex;
        flex-direction: column;
    }

    h4 {
        margin: 0 0 4px;
        font-size: 20px;
    }

    .note .text-area {
        padding-top: 6px;
    }

    .files {
        width: 170px;
        font-size: 12px;
        gap: 4px;
        padding: 10px;
    }

    .file {
        padding: 3px 8px 3px 18px;
        border-radius: 6px;
    }

    .file.selected {
        background: var(--fill-3);
    }

    .code {
        flex: 1;
        margin: 0;
        padding: 14px 16px;
        font-family: var(--mono);
        font-size: 11.5px;
        line-height: 1.6;
        color: var(--label);
        overflow: hidden;
        min-width: 0;
    }

    .k {
        color: #c045c9;
    }

    .s {
        color: #d0763d;
    }

    .f {
        color: #3a7cf0;
    }

    .t {
        color: #2f9e8f;
    }

    .n {
        color: #8b6cf0;
    }

    .assistant {
        width: 250px;
        flex-shrink: 0;
        display: flex;
        flex-direction: column;
        padding: 12px;
        border-left: 1px solid var(--fill-2);
        background: var(--fill);
    }

    .assistant-title {
        font-weight: 600;
    }

    .assistant-hint {
        flex: 1;
        color: var(--label-2);
        font-size: 12px;
        padding-top: 4px;
    }

    .assistant .compose {
        border-radius: 12px;
        min-height: 64px;
        background: var(--app-bg);
    }

    .placeholder {
        color: var(--label-3);
    }

    .caret {
        display: inline-block;
        width: 1.5px;
        height: 1.15em;
        margin: 0 1px -0.2em 0;
        background: #0a84ff;
        animation: blink 1.06s steps(1) infinite;
    }

    @keyframes blink {
        50% {
            opacity: 0;
        }
    }
</style>
