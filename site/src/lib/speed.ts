// The README's "Speed" numbers (bench/README.md, "In-app latency" and "Comparison with other runtimes"):
// M4 Pro, macOS 27.0, October 2026, 1 s idle before each clip or dictation. Update them together.

export interface Bar {
    name: string;
    /** Median, ms. */
    value: number;
    p90?: number;
    detail?: string;
    localflow?: boolean;
}

export interface Chart {
    title: string;
    subtitle: string;
    groups: { label?: string; bars: Bar[] }[];
}

export const releaseToPaste = { plain: 57, cleanup: 82, dictations: 55 };

export const charts: Chart[] = [
    {
        title: "Speech to text",
        subtitle: "Median time from the end of the recording to the transcript, 420 clips of 2–25 s from six public test sets.",
        groups: [
            {
                label: "English (Parakeet Unified 0.6B)",
                bars: [
                    { name: "Localflow", detail: "Neural Engine and CPU", value: 34, p90: 52, localflow: true },
                    { name: "FluidAudio 0.17.7", detail: "Neural Engine", value: 86, p90: 109 },
                ],
            },
            {
                label: "Multilingual (Parakeet v3 0.6B)",
                bars: [
                    { name: "Localflow", detail: "Neural Engine and CPU", value: 35, p90: 51, localflow: true },
                    { name: "FluidAudio 0.17.7", detail: "Neural Engine", value: 83, p90: 108 },
                    { name: "MLX, mlx-audio 0.6.1", detail: "GPU", value: 101, p90: 173 },
                ],
            },
        ],
    },
    {
        title: "Transcript cleanup",
        subtitle: "Median time per dictation with S1-mini (8-bit weights), 220 dictations.",
        groups: [
            {
                bars: [
                    { name: "Localflow", detail: "CPU, NEON and SME", value: 37, p90: 90, localflow: true },
                    { name: "Localflow, SME off", detail: "the code path of chips before M4", value: 45, p90: 97, localflow: true },
                    { name: "llama.cpp b11887", detail: "Metal, n-gram drafting", value: 78, p90: 170 },
                    { name: "llama.cpp b11887", detail: "CPU, n-gram drafting", value: 84, p90: 194 },
                    { name: "MLX, mlx_lm 0.32.2", detail: "GPU, no drafting", value: 136, p90: 222 },
                ],
            },
        ],
    },
    {
        title: "With another app using the GPU",
        subtitle: "Medians while a GPU load runs the whole time (60 clips and 55 dictations).",
        groups: [
            {
                label: "Speech to text (Parakeet v3)",
                bars: [
                    { name: "Localflow", value: 21, p90: 41, localflow: true },
                    { name: "FluidAudio", value: 48, p90: 85 },
                    { name: "MLX", value: 661, p90: 1149 },
                ],
            },
            {
                label: "Cleanup",
                bars: [
                    { name: "Localflow", value: 22, p90: 67, localflow: true },
                    { name: "llama.cpp, CPU", value: 61, p90: 183 },
                    { name: "llama.cpp, Metal", value: 758, p90: 2356 },
                    { name: "MLX", value: 1717, p90: 3678 },
                ],
            },
        ],
    },
];
