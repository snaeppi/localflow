// Start and stop sounds. The app plays macOS's "Tink" and "Pop", which can't be shipped here; these are soft
// stand-ins made with Web Audio, at the app's levels (0.2 and 0.15 of the volume setting).
let context: AudioContext | undefined;

function blip(frequency: number, end: number, duration: number, gain: number) {
    context ??= new AudioContext();
    const t = context.currentTime;
    const osc = context.createOscillator();
    const amp = context.createGain();
    osc.type = "sine";
    osc.frequency.setValueAtTime(frequency, t);
    osc.frequency.exponentialRampToValueAtTime(end, t + duration);
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(gain, t + 0.004);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + duration);
    osc.connect(amp).connect(context.destination);
    osc.start(t);
    osc.stop(t + duration);
}

export const playStart = (volume: number) => blip(1760, 1500, 0.12, 0.2 * volume);
export const playStop = (volume: number) => blip(520, 260, 0.09, 0.15 * volume * 1.6);
