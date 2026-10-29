// The recording window's waveform (RecordingWindow.swift `WaveformBuffer`): levels arrive one per 20 ms, two
// per bar (the louder one, so syllables stay visible), and the bars scroll one per 40 ms.
export class WaveformBuffer {
    bars: number[];
    private queue: number[] = [];
    private pending: number[] = [];
    private lastAdvance = 0;
    private readonly step = 0.04;

    constructor(private readonly count = 26) {
        this.bars = new Array(count).fill(0);
    }

    reset() {
        this.bars = new Array(this.count).fill(0);
        this.queue = [];
        this.pending = [];
    }

    /** Levels from the meter, one per 20 ms. */
    push(levels: number[]) {
        this.pending.push(...levels);
        while (this.pending.length >= 2) {
            this.queue.push(Math.max(this.pending.shift()!, this.pending.shift()!));
        }
        if (this.queue.length > 12) this.queue.splice(0, this.queue.length - 12); // Never lag behind live audio.
    }

    /** `time` in seconds. */
    advance(time: number) {
        if (this.lastAdvance === 0 || time - this.lastAdvance > 0.5) this.lastAdvance = time;
        while (time - this.lastAdvance >= this.step) {
            this.lastAdvance += this.step;
            const next = this.queue.length ? this.queue.shift()! : (this.bars[this.bars.length - 1] ?? 0) * 0.6;
            this.bars.shift();
            this.bars.push(next);
        }
    }
}
