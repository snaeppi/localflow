// lf_pass's measurement on llama.cpp: N tokens after POS cached, logits for every one of them (what
// llama-server's speculative decoding asks for), timed through llama_synchronize. Picking the next
// token from the logits isn't timed, which Localflow's engine does inside the pass.
// usage: llama_pass MODEL GPU_LAYERS THREADS [POS] [REPS]   (GPU_LAYERS 0: CPU only, 99: Metal)
#include "llama.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static int cmp(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static void quiet(enum ggml_log_level level, const char *text, void *data) {
    (void)data;
    if (level == GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
}

static void fill(struct llama_batch *batch, int n, int pos, int all_logits) {
    batch->n_tokens = n;
    for (int i = 0; i < n; i++) {
        batch->token[i] = 1000 + (i * 7919) % 50000;  // as lf_pass
        batch->pos[i] = pos + i;
        batch->n_seq_id[i] = 1;
        batch->seq_id[i][0] = 0;
        batch->logits[i] = all_logits || i == n - 1;
    }
}

int main(int argc, char **argv) {
    if (argc < 4) return fprintf(stderr, "usage: llama_pass MODEL GPU_LAYERS THREADS [POS] [REPS]\n"), 2;
    const int gpu_layers = atoi(argv[2]), threads = atoi(argv[3]);
    const int pos = argc > 4 ? atoi(argv[4]) : 130, reps = argc > 5 ? atoi(argv[5]) : 30;
    if (reps < 1 || reps > 200) return fprintf(stderr, "REPS: 1 to 200\n"), 2;
    llama_log_set(quiet, NULL);
    llama_backend_init();
    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = gpu_layers;
    struct llama_model *model = llama_model_load_from_file(argv[1], model_params);
    if (!model) return fprintf(stderr, "can't load %s\n", argv[1]), 1;
    struct llama_context_params params = llama_context_default_params();
    params.n_ctx = 2048;
    params.n_batch = params.n_ubatch = 512;
    params.n_threads = params.n_threads_batch = threads;
    params.no_perf = true;
    struct llama_context *ctx = llama_init_from_model(model, params);
    if (!ctx) return fprintf(stderr, "can't create a context\n"), 1;
    llama_memory_t memory = llama_get_memory(ctx);
    struct llama_batch batch = llama_batch_init(512, 0, 1);
    fill(&batch, pos, 0, 0);
    if (llama_decode(ctx, batch)) return fprintf(stderr, "decode failed\n"), 1;
    const int sizes[] = { 1, 5, 11, 21, 32, 53, 128 };
    for (size_t s = 0; s < sizeof sizes / sizeof *sizes; s++) {
        const int n = sizes[s];
        double t[200];
        for (int r = -5; r < reps; r++) {
            llama_memory_seq_rm(memory, 0, pos, -1);
            fill(&batch, n, pos, 1);
            const double start = now_ms();
            if (llama_decode(ctx, batch)) return fprintf(stderr, "decode failed\n"), 1;
            llama_synchronize(ctx);
            if (r >= 0) t[r] = now_ms() - start;
        }
        qsort(t, reps, sizeof *t, cmp);
        printf("N=%3d  median %7.2f  best %7.2f ms\n", n, t[reps / 2], t[0]);
    }
    llama_batch_free(batch);
    llama_free(ctx);
    llama_model_free(model);
    return 0;
}
