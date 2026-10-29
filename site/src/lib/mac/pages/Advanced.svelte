<script lang="ts">
    import Atom from "@lucide/svelte/icons/atom";
    import Card from "../Card.svelte";
    import DeviceButton from "../DeviceButton.svelte";
    import Divider from "../Divider.svelte";
    import InfoButton from "../InfoButton.svelte";
    import Page from "../Page.svelte";
    import Popup from "../Popup.svelte";
    import Row from "../Row.svelte";
    import SectionTitle from "../SectionTitle.svelte";
    import Switch from "../Switch.svelte";
    import { navigation, settings } from "../../settings.svelte";

    const durations = [10, 30, 60, 120, 300, 600, 1800, 3600, 0];
    const duration = (s: number) =>
        s === 0 ? "Always" : s < 60 ? `${s} seconds` : s === 60 ? "1 minute" : s < 3600 ? `${s / 60} minutes` : "1 hour";
</script>

{#snippet experimental()}
    <span class="secondary badge" title="Experimental"><Atom size={13} strokeWidth={1.7} /></span>
{/snippet}

<Page title="Advanced settings" back={() => (navigation.advanced = false)}>
    {#snippet trailing()}<DeviceButton />{/snippet}
    <SectionTitle title="Application" first />
    <Card>
        <Row title="Show in Dock" info="Keeps Localflow in the Dock. Otherwise it's there only while one of its windows is open.">
            <Switch label="Show in Dock" bind:checked={settings.showInDock} />
        </Row>
        <Divider />
        <Row
            title="Start recording on menu bar click"
            info="A click on Localflow's icon in the menu bar starts a dictation, and another click finishes it. Right-click the icon for its menu."
        >
            <Switch label="Start recording on menu bar click" bind:checked={settings.recordOnMenuBarClick} />
        </Row>
    </Card>

    <SectionTitle title="Models" />
    <Card>
        <Row
            title="Model active duration"
            info="How long the speech model, and the cleanup model when it's on, stay loaded after you dictate. When you start dictating again they load while you speak, in a fraction of a second."
        >
            <Popup
                label="Model active duration"
                value={settings.modelActiveDuration}
                options={durations.map((d) => ({ value: d, title: duration(d) }))}
                onchange={(v) => (settings.modelActiveDuration = v)}
            />
        </Row>
    </Card>

    <SectionTitle title="Audio processing" />
    <Card>
        <Row
            title="Silence removal"
            info="Shortens long pauses before a recording is transcribed, so long dictations with many pauses are transcribed faster. Speech much quieter than the rest can be taken for a pause."
        >
            <Switch label="Silence removal" bind:checked={settings.silenceRemoval} />
        </Row>
        <Divider />
        <Row
            title="Dynamic normalization"
            info="Evens out the loudness of a recording before it's transcribed. Fewer mistakes with quiet or distant microphones."
        >
            <Switch label="Dynamic normalization" bind:checked={settings.normalization} />
        </Row>
    </Card>

    <SectionTitle title="App folder location" />
    <Card>
        <div class="folder">
            <span class="path">~/Localflow</span>
            <button class="push">Change Folder…</button>
            <InfoButton
                text="Where Localflow keeps its settings, vocabulary and the cleanup model. Choose a folder you back up, or one with a Localflow folder from another Mac to use its settings."
            />
        </div>
    </Card>

    <SectionTitle title="Text input" />
    <Card>
        <Row
            title="Clipboard content"
            info="To paste a dictation, Localflow puts it on your clipboard. This sets what your clipboard holds afterwards."
        >
            <Popup
                label="Clipboard content"
                value={settings.clipboard}
                options={[
                    { value: "keep", title: "Keep what I have copied" },
                    { value: "replace", title: "Replace with dictation" },
                ]}
                onchange={(v) => (settings.clipboard = v)}
            />
        </Row>
        <Divider />
        <Row
            title="Clipboard history"
            info="Lets clipboard history apps such as Maccy, Paste or Alfred keep a copy of each dictation. Otherwise dictations are marked so those apps skip them."
        >
            <Switch label="Clipboard history" bind:checked={settings.clipboardHistory} />
        </Row>
        <Divider />
        <Row title="Paste result text" info="Pastes each dictation where you're typing. Turned off, the text is only put on your clipboard.">
            <Switch label="Paste result text" bind:checked={settings.pasteResult} />
        </Row>
        <Divider />
        <Row
            title="Hold Shift to send after paste"
            info="Hold Shift as you finish a dictation and Localflow presses Return after pasting it, to send a chat message."
        >
            <span class="pair">{@render experimental()}<Switch label="Hold Shift to send after paste" bind:checked={settings.shiftToSend} /></span>
        </Row>
        <Divider />
        <Row
            title="Simulate keypresses"
            info="Types each dictation character by character instead of pasting it, for apps that don't accept pasting."
        >
            <span class="pair">{@render experimental()}<Switch label="Simulate keypresses" bind:checked={settings.simulateKeypresses} /></span>
        </Row>
    </Card>

    <SectionTitle title="Diagnostics" />
    <Card>
        <Row
            title="Save recordings"
            info="Keeps each recording and its transcript in the recordings folder inside the app folder, for testing speech models on your own voice. They stay on this Mac; delete the folder to remove them."
        >
            <Switch label="Save recordings" bind:checked={settings.saveRecordings} />
        </Row>
    </Card>
</Page>

<style>
    .folder {
        display: flex;
        align-items: center;
        gap: 10px;
        min-height: 45px;
        padding: 0 16px;
    }

    .path {
        flex: 1;
    }

    .pair {
        display: flex;
        align-items: center;
        gap: 14px;
    }

    .badge {
        display: inline-flex;
    }
</style>
