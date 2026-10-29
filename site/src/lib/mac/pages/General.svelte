<script lang="ts">
    import ChevronRight from "@lucide/svelte/icons/chevron-right";
    import Card from "../Card.svelte";
    import ChoiceTiles from "../ChoiceTiles.svelte";
    import DeviceButton from "../DeviceButton.svelte";
    import Divider from "../Divider.svelte";
    import Page from "../Page.svelte";
    import RecordingWindowTile from "../RecordingWindowTile.svelte";
    import Row from "../Row.svelte";
    import SectionTitle from "../SectionTitle.svelte";
    import ShortcutField from "../ShortcutField.svelte";
    import Switch from "../Switch.svelte";
    import ThemeTile from "../ThemeTile.svelte";
    import { escape, navigation, rightCommand, settings } from "../../settings.svelte";
</script>

<Page title="General">
    {#snippet trailing()}<DeviceButton />{/snippet}
    <Card>
        <Row title="Theme" top>
            <ChoiceTiles
                value={settings.theme}
                options={[
                    { value: "auto", title: "Auto" },
                    { value: "light", title: "Light" },
                    { value: "dark", title: "Dark" },
                ]}
                onchange={(v) => (settings.theme = v)}
            >
                {#snippet tile(value, selected)}<ThemeTile theme={value} {selected} />{/snippet}
            </ChoiceTiles>
        </Row>
        <Divider />
        <Row title="Recording window" top>
            <ChoiceTiles
                value={settings.recordingWindow}
                spacing={12}
                options={[
                    { value: "on", title: "On" },
                    { value: "off", title: "Off" },
                ]}
                onchange={(v) => (settings.recordingWindow = v)}
            >
                {#snippet tile(value, selected)}<RecordingWindowTile style={value} {selected} />{/snippet}
            </ChoiceTiles>
        </Row>
        {#if settings.recordingWindow === "on"}
            <Divider />
            <Row
                title="Always show"
                info="Keeps the recording window on screen between dictations, so you can click it to start and finish one. Drag it to any edge or the middle of a screen."
            >
                <Switch label="Always show" bind:checked={settings.alwaysShow} />
            </Row>
        {/if}
    </Card>

    <SectionTitle title="Keyboard shortcuts" />
    <Card>
        <Row title="Toggle recording" subtitle="Starts and stops recordings">
            <ShortcutField
                kind="key"
                value={settings.toggleShortcut}
                defaultValue={rightCommand}
                others={[settings.cancelShortcut]}
                onchange={(v) => (settings.toggleShortcut = v)}
            />
        </Row>
        <Divider />
        <Row title="Cancel recording" subtitle="Discards the active recording">
            <ShortcutField
                kind="key"
                value={settings.cancelShortcut}
                defaultValue={escape}
                others={[settings.toggleShortcut, settings.pushToTalk]}
                allowsNone={false}
                allowsBareKeys
                modifierKeys={false}
                onchange={(v) => (settings.cancelShortcut = v ?? escape)}
            />
        </Row>
        <Divider />
        <Row
            title="Push to talk"
            subtitle="Hold to record, release when done"
            info="With the same key as Toggle recording, one key does both: hold it to talk, or tap it to start and tap again to finish. A modifier key used on its own still works in shortcuts: Right ⌘ + C copies as usual."
        >
            <ShortcutField
                kind="key"
                value={settings.pushToTalk}
                defaultValue={rightCommand}
                others={[settings.cancelShortcut]}
                onchange={(v) => (settings.pushToTalk = v)}
            />
        </Row>
        <Divider />
        <Row title="Mouse shortcut" subtitle="Tap to toggle, or hold and release when done">
            <ShortcutField
                kind="mouse"
                value={settings.mouseShortcut}
                defaultValue={null}
                onchange={(v) => (settings.mouseShortcut = v)}
            />
        </Row>
    </Card>

    <SectionTitle title="Application" />
    <Card>
        <Row title="Launch at login">
            <Switch label="Launch at login" bind:checked={settings.launchAtLogin} />
        </Row>
    </Card>
    <Card style="margin-top: 14px">
        <button class="advanced" onclick={() => (navigation.advanced = true)}>
            <Row title="Advanced settings">
                <span class="secondary chevron"><ChevronRight size={14} strokeWidth={2.4} /></span>
            </Row>
        </button>
    </Card>
</Page>

<style>
    .advanced {
        display: block;
        width: 100%;
        text-align: left;
    }

    .chevron {
        display: inline-flex;
    }
</style>
