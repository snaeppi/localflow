<script lang="ts">
    import CirclePause from "@lucide/svelte/icons/circle-pause";
    import CirclePlay from "@lucide/svelte/icons/circle-play";
    import Volume1 from "@lucide/svelte/icons/volume-1";
    import VolumeX from "@lucide/svelte/icons/volume-x";
    import Card from "../Card.svelte";
    import DeviceButton from "../DeviceButton.svelte";
    import Divider from "../Divider.svelte";
    import Page from "../Page.svelte";
    import Popup from "../Popup.svelte";
    import Row from "../Row.svelte";
    import SectionTitle from "../SectionTitle.svelte";
    import Slider from "../Slider.svelte";
    import Switch from "../Switch.svelte";
    import { settings } from "../../settings.svelte";
    import { playStart } from "../../sounds";
</script>

<Page title="Sound">
    {#snippet trailing()}<DeviceButton />{/snippet}
    <Card>
        <Row title="Sound effects" info="A soft sound when a recording starts and stops.">
            <Switch label="Sound effects" bind:checked={settings.soundEffects} />
        </Row>
        {#if settings.soundEffects}
            <Divider />
            <Row title="Volume">
                <Slider
                    label="Volume"
                    value={settings.soundVolume}
                    onchange={(v) => (settings.soundVolume = v)}
                    onend={() => playStart(settings.soundVolume)}
                />
            </Row>
        {/if}
    </Card>

    <SectionTitle title="Recording" />
    <Card>
        <Row title="Sound while recording">
            <Popup
                label="Sound while recording"
                value={settings.whileRecording}
                options={[
                    { value: "keepPlaying", title: "Keep Playing", icon: CirclePlay },
                    { value: "pause", title: "Pause", icon: CirclePause },
                    { value: "mute", title: "Mute", icon: VolumeX },
                    { value: "lower", title: "Lower", icon: Volume1 },
                ]}
                onchange={(v) => (settings.whileRecording = v)}
            />
        </Row>
        <Divider />
        <Row
            title="Automatically increase microphone volume"
            info="Turns the microphone's input volume all the way up while you dictate, and back afterwards."
        >
            <Switch label="Automatically increase microphone volume" bind:checked={settings.boostMicrophone} />
        </Row>
    </Card>
</Page>
