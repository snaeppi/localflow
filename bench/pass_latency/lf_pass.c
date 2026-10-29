// One forward pass of the cleanup model on Localflow's engine: N tokens after POS cached, the next
// token predicted after every one of them (as a speculative pass verifies a draft). Median and best
// of REPS back-to-back passes per N, after 5 unmeasured ones.
// usage: lf_pass MODEL [POS] [REPS]   (MODEL: the app's converted file, ~/Localflow/models/s1-mini-2.gguf)
#include "LocalflowEngine.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static int cmp(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    if (argc < 2) return fprintf(stderr, "usage: lf_pass MODEL [POS] [REPS]\n"), 2;
    const int pos = argc > 2 ? atoi(argv[2]) : 130, reps = argc > 3 ? atoi(argv[3]) : 30;
    if (reps < 1 || reps > 200) return fprintf(stderr, "REPS: 1 to 200\n"), 2;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);  // as the app's Rewriter actor
    lf_model *model = lf_load(argv[1], 2048, 512);
    if (!model) return fprintf(stderr, "can't load %s\n", argv[1]), 1;
    int32_t tokens[512], argmax[512];
    for (int i = 0; i < 512; i++) tokens[i] = 1000 + (i * 7919) % 50000;
    lf_decode(model, tokens, pos, 0, 0, argmax);
    const int sizes[] = { 1, 5, 11, 21, 32, 53, 128 };
    for (size_t s = 0; s < sizeof sizes / sizeof *sizes; s++) {
        const int n = sizes[s];
        double t[200];
        for (int r = 0; r < 5; r++) lf_decode(model, tokens, n, pos, n, argmax);
        for (int r = 0; r < reps; r++) {
            const double start = now_ms();
            lf_decode(model, tokens, n, pos, n, argmax);
            t[r] = now_ms() - start;
        }
        qsort(t, reps, sizeof *t, cmp);
        printf("N=%3d  median %7.2f  best %7.2f ms\n", n, t[reps / 2], t[0]);
    }
    lf_free(model);
    return 0;
}
