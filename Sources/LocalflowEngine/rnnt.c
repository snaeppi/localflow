// The speech models' transducer decoders on the CPU, in place of FluidAudio's two CoreML models
// called once per frame and per token: greedy RNNT decoding of Parakeet Unified 0.6B (~35 ms of a
// dictation on cold cores became ~3 ms) and greedy TDT decoding of Parakeet TDT 0.6B v3 (also ~35
// ms to ~3 ms; bench/README.md). Both have the same prediction network, an embedding and two
// LSTM layers of 640, and joint: the encoder frame and the prediction projected to 640, added,
// ReLU, then the outputs: one logit per token, the last token being blank (1025 tokens; v3 8193),
// and for TDT 5 logits for how many frames to advance. The weights are the CoreML bundles' fp16
// weights, used in place; the arithmetic is fp32, where the CoreML models compute in fp16.
#include "LocalflowEngine.h"
#include "internal.h"

#include <Accelerate/Accelerate.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum { H = 640, GATES = 4 * H, ENC = 1024, DURATIONS = 5 };
#define MAX_SYMBOLS 10        // per frame, as FluidAudio's UnifiedConfig and TdtConfig
#define MAX_TDT_TOKENS 150    // per window before decoding stops, as FluidAudio's TdtConfig
#define TDT_FLUSH_STEPS 10    // the last window's end-of-audio probes, and the blanks in a row that end them
#define TDT_FLUSH_BLANKS 5
#define ROWS 2                // RNNT frames per joint evaluation; per dictation 1 took +0.4 ms, 4 +0.1 ms, 8 +0.6 ms

/// Where the tensors are in the bundles' weight files (their model.mil): the decoder's embedding,
/// input-to-hidden, hidden-to-hidden weights and biases of both LSTM layers. The joints share one
/// layout up to the output bias, after the output weights.
typedef struct {
    int tokens, durations;
    uint64_t w_ih[2], w_hh[2], bias[2], b_out;
} layout;

static const layout unified = { 1025, 0, { 1312128, 7871040 }, { 4588992, 11147904 }, { 7865856, 14424768 }, 3444864 };
static const layout tdt_v3 = { 8193, DURATIONS, { 10487168, 17046080 }, { 13764032, 20322944 }, { 17040896, 23599808 },
                               12626304 };

struct lf_rnnt {
    void *decoder_map, *joint_map;
    size_t decoder_size, joint_size;
    int tokens, blank, outputs;     // outputs: tokens, then durations
    const __fp16 *embed, *w_ih[2], *w_hh[2], *bias[2], *w_pred, *b_pred, *w_out, *b_out;
    float *w_enc, *b_enc;           // in fp32 for sgemm
    float *f;                       // [frames][H] the encoder frames' projections
    int f_frames;
    // The decode being run.
    int frames, valid, max, n;
    bool last;
    int32_t *tokens_out, *token_frames, *durations_out;
    float *probabilities;
    // LSTM state (h double-buffered: every thread reads all of it, each writes its units), the
    // prediction's projection, each thread's best token per frame of the last two evaluations.
    float h[2][2][H], c[2][H], g[H];
    float best_value[2][16][ROWS];
    int32_t best_token[2][16][ROWS];
    // TDT: every output of the last evaluation (each thread reads back only its own), and of the last
    // two evaluations the durations and each thread's sum of exp(logit - maximum) over its tokens.
    float *logits;
    float duration_logits[2][DURATIONS];
    float exp_sum[2][16];
    float *z;                       // per thread: [ROWS][H]
    lf_pool pool;
};

static void *map_file(const char *path, size_t *size) {
    const int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        return NULL;
    }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    *size = (size_t)st.st_size;
    return p;
}

/// A tensor of a CoreML weight file: a 64-byte header at `at` (sentinel, data type 1 = fp16, size,
/// offset of the data), at the offsets the bundle's model.mil gives.
static const __fp16 *blob(const void *base, size_t size, uint64_t at, uint64_t count) {
    if (at + 64 > size) return NULL;
    const uint8_t *p = (const uint8_t *)base + at;
    uint32_t sentinel, type;
    uint64_t bytes, offset;
    memcpy(&sentinel, p, 4);
    memcpy(&type, p + 4, 4);
    memcpy(&bytes, p + 8, 8);
    memcpy(&offset, p + 16, 8);
    if (sentinel != 0xDEADBEEF || type != 1 || bytes != count * 2 || offset % 16 || offset + bytes > size) return NULL;
    return (const __fp16 *)((const uint8_t *)base + offset);
}

static float *to_f32(const __fp16 *src, size_t n) {
    float *dst = src ? malloc(n * sizeof(float)) : NULL;
    if (dst)
        for (size_t i = 0; i < n; i++) dst[i] = (float)src[i];
    return dst;
}

// MARK: Kernels

/// out[r] += W[r] · x for `rows` rows of H fp16 weights.
static void matvec(const __fp16 *W, const float *x, int rows, float *out) {
    int r = 0;
    for (; r + 4 <= rows; r += 4) {
        const __fp16 *w0 = W + (size_t)r * H, *w1 = w0 + H, *w2 = w1 + H, *w3 = w2 + H;
        float32x4_t a0 = vdupq_n_f32(0), b0 = a0, a1 = a0, b1 = a0, a2 = a0, b2 = a0, a3 = a0, b3 = a0;
        for (int k = 0; k < H; k += 8) {
            const float32x4_t xl = vld1q_f32(x + k), xh = vld1q_f32(x + k + 4);
            const float16x8_t v0 = vld1q_f16(w0 + k), v1 = vld1q_f16(w1 + k);
            const float16x8_t v2 = vld1q_f16(w2 + k), v3 = vld1q_f16(w3 + k);
            a0 = vfmaq_f32(a0, vcvt_f32_f16(vget_low_f16(v0)), xl), b0 = vfmaq_f32(b0, vcvt_high_f32_f16(v0), xh);
            a1 = vfmaq_f32(a1, vcvt_f32_f16(vget_low_f16(v1)), xl), b1 = vfmaq_f32(b1, vcvt_high_f32_f16(v1), xh);
            a2 = vfmaq_f32(a2, vcvt_f32_f16(vget_low_f16(v2)), xl), b2 = vfmaq_f32(b2, vcvt_high_f32_f16(v2), xh);
            a3 = vfmaq_f32(a3, vcvt_f32_f16(vget_low_f16(v3)), xl), b3 = vfmaq_f32(b3, vcvt_high_f32_f16(v3), xh);
        }
        out[r] += vaddvq_f32(vaddq_f32(a0, b0)), out[r + 1] += vaddvq_f32(vaddq_f32(a1, b1));
        out[r + 2] += vaddvq_f32(vaddq_f32(a2, b2)), out[r + 3] += vaddvq_f32(vaddq_f32(a3, b3));
    }
    for (; r < rows; r++) {
        const __fp16 *w = W + (size_t)r * H;
        float32x4_t a = vdupq_n_f32(0), b = a;
        for (int k = 0; k < H; k += 8) {
            const float16x8_t v = vld1q_f16(w + k);
            a = vfmaq_f32(a, vcvt_f32_f16(vget_low_f16(v)), vld1q_f32(x + k));
            b = vfmaq_f32(b, vcvt_high_f32_f16(v), vld1q_f32(x + k + 4));
        }
        out[r] += vaddvq_f32(vaddq_f32(a, b));
    }
}

/// One output row of the joint for two frames: w · z0 and w · z1.
static void joint_row(const __fp16 *w, const float *z0, const float *z1, float *d0, float *d1) {
    float32x4_t a0 = vdupq_n_f32(0), b0 = a0, a1 = a0, b1 = a0;
    for (int k = 0; k < H; k += 8) {
        const float16x8_t v = vld1q_f16(w + k);
        const float32x4_t wl = vcvt_f32_f16(vget_low_f16(v)), wh = vcvt_high_f32_f16(v);
        a0 = vfmaq_f32(a0, wl, vld1q_f32(z0 + k)), b0 = vfmaq_f32(b0, wh, vld1q_f32(z0 + k + 4));
        a1 = vfmaq_f32(a1, wl, vld1q_f32(z1 + k)), b1 = vfmaq_f32(b1, wh, vld1q_f32(z1 + k + 4));
    }
    *d0 = vaddvq_f32(vaddq_f32(a0, b0));
    *d1 = vaddvq_f32(vaddq_f32(a1, b1));
}

static inline float sigmoid(float x) { return 1.0f / (1.0f + expf(-x)); }

// MARK: Prediction network

/// Thread ith's part [*a, *b) of n items, in multiples of `unit`.
static void share(int n, int unit, int ith, int nth, int *a, int *b) {
    const int units = (n + unit - 1) / unit;
    *a = units * ith / nth * unit;
    *b = units * (ith + 1) / nth * unit;
    if (*b > n) *b = n;
}

/// Feeds `token` to the prediction network and projects its output into r->g; thread ith does
/// LSTM units and projection rows [u0, u1).
static void step(lf_rnnt *r, int ith, int token, int cur[2]) {
    int u0, u1;
    share(H, 4, ith, r->pool.n_threads, &u0, &u1);
    float x[H], gates[4][H];
    for (int k = 0; k < H; k++) x[k] = (float)r->embed[(size_t)token * H + k];
    const float *in = x;
    for (int l = 0; l < 2; l++) {
        const float *h = r->h[l][cur[l]];
        float *next = r->h[l][!cur[l]];
        for (int q = 0; q < 4; q++) {
            for (int u = u0; u < u1; u++) gates[q][u - u0] = (float)r->bias[l][q * H + u];
            matvec(r->w_ih[l] + (size_t)(q * H + u0) * H, in, u1 - u0, gates[q]);
            matvec(r->w_hh[l] + (size_t)(q * H + u0) * H, h, u1 - u0, gates[q]);
        }
        // CoreML's gate order: input, forget, output, cell.
        for (int u = u0; u < u1; u++) {
            const float i = sigmoid(gates[0][u - u0]), f = sigmoid(gates[1][u - u0]);
            const float o = sigmoid(gates[2][u - u0]), cell = tanhf(gates[3][u - u0]);
            r->c[l][u] = f * r->c[l][u] + i * cell;
            next[u] = o * tanhf(r->c[l][u]);
        }
        cur[l] = !cur[l];
        lf_barrier(&r->pool);
        in = next;
    }
    for (int u = u0; u < u1; u++) r->g[u] = (float)r->b_pred[u];
    matvec(r->w_pred + (size_t)u0 * H, in, u1 - u0, r->g + u0);
    lf_barrier(&r->pool);
}

/// A fresh state, primed with blank as FluidAudio's decoders do.
static void start(lf_rnnt *r, int ith, int cur[2]) {
    int u0, u1;
    share(H, 4, ith, r->pool.n_threads, &u0, &u1);
    for (int l = 0; l < 2; l++)
        for (int u = u0; u < u1; u++) r->h[l][0][u] = r->c[l][u] = 0;
    lf_barrier(&r->pool);
    step(r, ith, r->blank, cur);
}

// MARK: RNNT

/// The decode loop, on every thread: each computes its share of every matrix product and takes the
/// same decisions from the shared results. The joint is evaluated for ROWS frames at a time with
/// the current prediction; after an emission the frames that follow it are evaluated again.
static void rnnt_decode(void *p, int ith) {
    lf_rnnt *r = p;
    const int nth = r->pool.n_threads, frames = r->frames, max = r->max, blank = r->blank;
    int32_t *tokens = r->tokens_out, *token_frames = r->token_frames;
    int v0, v1;
    share(r->tokens, 1, ith, nth, &v0, &v1);
    int cur[2] = { 0, 0 };
    start(r, ith, cur);
    float *z = r->z + (size_t)ith * ROWS * H;
    int n = 0, t = 0, symbols = 0, evaluation = 0;
    while (t < frames) {
        const int rows = frames - t < ROWS ? frames - t : ROWS, buf = evaluation++ & 1;
        for (int i = 0; i < ROWS; i++) {
            const float *f = r->f + (size_t)(i < rows ? t + i : t) * H;
            for (int k = 0; k < H; k++) z[i * H + k] = fmaxf(f[k] + r->g[k], 0.0f);
        }
        float *best = r->best_value[buf][ith];
        int32_t *best_token = r->best_token[buf][ith];
        for (int i = 0; i < ROWS; i++) best[i] = -INFINITY, best_token[i] = v0;
        for (int v = v0; v < v1; v++) {
            float d[ROWS];
            joint_row(r->w_out + (size_t)v * H, z, z + H, &d[0], &d[1]);
            const float bias = (float)r->b_out[v];
            for (int i = 0; i < ROWS; i++)
                if (d[i] + bias > best[i]) best[i] = d[i] + bias, best_token[i] = v;
        }
        lf_barrier(&r->pool);
        // The first maximum, as CoreML's argmax: threads hold ascending slices of the vocabulary.
        int i = 0, token = blank;
        for (; i < rows; i++) {
            float value = -INFINITY;
            for (int j = 0; j < nth; j++)
                if (r->best_value[buf][j][i] > value) {
                    value = r->best_value[buf][j][i];
                    token = r->best_token[buf][j][i];
                }
            if (token != blank) break;
            symbols = 0;
        }
        t += i;
        if (token == blank) continue;
        if (ith == 0 && n < max) tokens[n] = token, token_frames[n] = t;
        n++;
        step(r, ith, token, cur);
        if (++symbols == MAX_SYMBOLS) t++, symbols = 0;
    }
    if (ith == 0) r->n = n < max ? n : max;
    lf_barrier(&r->pool);
}

// MARK: TDT

typedef struct {
    int token, duration;
    float maximum;   // the token's logit
    int buf;
} decision;

/// The joint at encoder frame t with the current prediction: the most likely token (the first
/// maximum, as CoreML's argmax) and duration, the same on every thread.
static decision evaluate(lf_rnnt *r, int ith, int t, int *evaluation) {
    const int nth = r->pool.n_threads, buf = (*evaluation)++ & 1;
    int v0, v1;
    share(r->outputs, 4, ith, nth, &v0, &v1);
    float *z = r->z + (size_t)ith * ROWS * H, *logits = r->logits;
    const float *f = r->f + (size_t)t * H;
    for (int k = 0; k < H; k++) z[k] = fmaxf(f[k] + r->g[k], 0.0f);
    for (int v = v0; v < v1; v++) logits[v] = (float)r->b_out[v];
    matvec(r->w_out + (size_t)v0 * H, z, v1 - v0, logits + v0);
    float best = -INFINITY;
    int best_token = v0;
    const int end = v1 < r->tokens ? v1 : r->tokens;
    for (int v = v0; v < end; v++)
        if (logits[v] > best) best = logits[v], best_token = v;
    r->best_value[buf][ith][0] = best;
    r->best_token[buf][ith][0] = best_token;
    for (int v = v0 > r->tokens ? v0 : r->tokens; v < v1; v++) r->duration_logits[buf][v - r->tokens] = logits[v];
    lf_barrier(&r->pool);
    decision d = { r->blank, 0, -INFINITY, buf };
    for (int j = 0; j < nth; j++)
        if (r->best_value[buf][j][0] > d.maximum) d.maximum = r->best_value[buf][j][0], d.token = r->best_token[buf][j][0];
    for (int i = 1; i < DURATIONS; i++)
        if (r->duration_logits[buf][i] > r->duration_logits[buf][d.duration]) d.duration = i;
    return d;   // durations 0–4 frames, by index
}

/// Records an emitted token: its softmax probability over the tokens (the confidence FluidAudio
/// keeps) needs every thread's sum, so each adds its own here and thread 0 finishes after `step`'s
/// barriers, in `record`.
static void add_exp_sum(lf_rnnt *r, int ith, decision d) {
    int v0, v1;
    share(r->outputs, 4, ith, r->pool.n_threads, &v0, &v1);
    const int end = v1 < r->tokens ? v1 : r->tokens;
    float sum = 0;
    for (int v = v0; v < end; v++) sum += expf(r->logits[v] - d.maximum);
    r->exp_sum[d.buf][ith] = sum;
}

static void record(lf_rnnt *r, int n, decision d, int frame, int duration) {
    if (n >= r->max) return;
    float sum = 0;
    for (int j = 0; j < r->pool.n_threads; j++) sum += r->exp_sum[d.buf][j];
    r->tokens_out[n] = d.token;
    r->token_frames[n] = frame;
    r->durations_out[n] = duration;
    r->probabilities[n] = sum >= 1 ? 1 / sum : 0;
}

/// FluidAudio's TdtDecoderV3.decodeWithTimings from a fresh state, on every thread. A blank's
/// duration says how many frames to skip without updating the prediction; a token is emitted at the
/// frame it was predicted at and then advances by its own duration. Quirks kept for the same output:
/// a token whose duration reaches past the last frame isn't emitted, the second token at a frame
/// with duration 0 advances by one, decoding stops after 150 tokens, and the last window then probes
/// its final frames (the end-of-audio flush).
static void tdt_decode(void *p, int ith) {
    lf_rnnt *r = p;
    const int count = r->frames, valid = r->valid < count ? r->valid : count, last = valid - 1;
    int cur[2] = { 0, 0 };
    start(r, ith, cur);
    int n = 0, t = 0, safe = 0, evaluation = 0, processed = 0, last_emission = -1, emissions = 0;
    bool active = t < valid;
    while (active) {
        decision d = evaluate(r, ith, safe, &evaluation);
        int duration = d.duration, at = t;
        bool blank = d.token == r->blank;
        if (!blank && duration == 0 && t == last_emission && emissions >= 1) duration = 1;
        if (blank && duration == 0) duration = 1;
        t += duration;
        safe = t < last ? t : last;
        active = t < valid;
        while (active && blank) {
            at = t;
            d = evaluate(r, ith, safe, &evaluation);
            duration = d.duration;
            blank = d.token == r->blank;
            if (blank && duration == 0) duration = 1;
            t += duration;
            safe = t < last ? t : last;
            active = t < valid;
        }
        if (active && !blank) {
            if (++processed > MAX_TDT_TOKENS) break;
            add_exp_sum(r, ith, d);
            step(r, ith, d.token, cur);
            if (ith == 0) record(r, n, d, at, duration);
            n++;
            if (at == last_emission) emissions++;
            else last_emission = at, emissions = 1;
            if (emissions >= MAX_SYMBOLS) {
                t = t + 1 < last ? t + 1 : last;
                safe = t < last ? t : last;
                emissions = 0;
                last_emission = -1;
            }
        }
        active = t < valid;
    }
    if (r->last) {
        int final = t, blanks = 0;
        for (int i = 0; i < TDT_FLUSH_STEPS && blanks < TDT_FLUSH_BLANKS; i++) {
            const int frames[3] = { final, last, last - 1 > 0 ? last - 1 : 0 };
            const int frame = frames[i % 3] < count - 1 ? frames[i % 3] : count - 1;
            const decision d = evaluate(r, ith, frame, &evaluation);
            if (d.token == r->blank) {
                blanks++;
            } else {
                blanks = 0;
                add_exp_sum(r, ith, d);
                step(r, ith, d.token, cur);
                if (ith == 0) record(r, n, d, final < last ? final : last, d.duration);
                n++;
            }
            final += d.duration > 1 ? d.duration : 1;
            if (final > valid) final = valid;
        }
    }
    if (ith == 0) r->n = n < r->max ? n : r->max;
    lf_barrier(&r->pool);
}

// MARK: API

void lf_rnnt_free(lf_rnnt *r) {
    if (!r) return;
    lf_pool_stop(&r->pool);
    if (r->decoder_map) munmap(r->decoder_map, r->decoder_size);
    if (r->joint_map) munmap(r->joint_map, r->joint_size);
    free(r->w_enc);
    free(r->b_enc);
    free(r->f);
    free(r->logits);
    free(r->z);
    free(r);
}

static lf_rnnt *load(const char *decoder_weights, const char *joint_weights, const layout *m,
                     void (*job)(void *, int), int n_threads) {
    lf_rnnt *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->decoder_map = map_file(decoder_weights, &r->decoder_size);
    r->joint_map = map_file(joint_weights, &r->joint_size);
    if (!r->decoder_map || !r->joint_map) {
        lf_rnnt_free(r);
        return NULL;
    }
    r->tokens = m->tokens;
    r->blank = m->tokens - 1;
    r->outputs = m->tokens + m->durations;
    const void *d = r->decoder_map, *j = r->joint_map;
    const size_t ds = r->decoder_size, js = r->joint_size;
    r->embed = blob(d, ds, 64, (uint64_t)r->tokens * H);
    for (int l = 0; l < 2; l++) {
        r->w_ih[l] = blob(d, ds, m->w_ih[l], (uint64_t)GATES * H);
        r->w_hh[l] = blob(d, ds, m->w_hh[l], (uint64_t)GATES * H);
        r->bias[l] = blob(d, ds, m->bias[l], GATES);
    }
    r->w_enc = to_f32(blob(j, js, 64, (uint64_t)H * ENC), (size_t)H * ENC);
    r->b_enc = to_f32(blob(j, js, 1310848, H), H);
    r->w_pred = blob(j, js, 1312192, (uint64_t)H * H);
    r->b_pred = blob(j, js, 2131456, H);
    r->w_out = blob(j, js, 2132800, (uint64_t)r->outputs * H);
    r->b_out = blob(j, js, m->b_out, (uint64_t)r->outputs);
    r->z = malloc((size_t)n_threads * ROWS * H * sizeof(float));
    r->logits = malloc((size_t)r->outputs * sizeof(float));
    if (!r->embed || !r->w_ih[0] || !r->w_hh[0] || !r->bias[0] || !r->w_ih[1] || !r->w_hh[1] || !r->bias[1] ||
        !r->w_enc || !r->b_enc || !r->w_pred || !r->b_pred || !r->w_out || !r->b_out || !r->z || !r->logits ||
        !lf_pool_start(&r->pool, n_threads, job, r)) {
        lf_rnnt_free(r);
        return NULL;
    }
    return r;
}

lf_rnnt *lf_rnnt_load(const char *decoder_weights, const char *joint_weights) {
    return load(decoder_weights, joint_weights, &unified, rnnt_decode, lf_performance_cores());
}

/// Two threads fewer than the performance cores, but at least 4 (or all of them): v3's joint is 8×
/// Unified's, so a thread that other processes preempt holds each barrier longer. On the M4 Pro (8
/// cores) with every core busy, a dictation's decode took p50 17 ms on 8 threads and 9 ms on 6, idle
/// 3.0 and 3.2 ms.
lf_rnnt *lf_tdt_load(const char *decoder_weights, const char *joint_weights) {
    const int cores = lf_performance_cores(), fewer = cores - 2 > 4 ? cores - 2 : 4;
    return load(decoder_weights, joint_weights, &tdt_v3, tdt_decode, fewer < cores ? fewer : cores);
}

void lf_rnnt_prepare(lf_rnnt *r) { lf_pool_prepare(&r->pool); }

/// The encoder frames' projections into r->f, then the decode on every thread.
static int run(lf_rnnt *r, const float *encoded, long stride, int frames) {
    if (frames > r->f_frames) {
        free(r->f);
        r->f = malloc((size_t)frames * H * sizeof(float));
        r->f_frames = r->f ? frames : 0;
        if (!r->f) return -1;
    }
    // The calling thread is one of the workers: every barrier waits for it.
    pthread_override_t boost = pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_USER_INTERACTIVE, 0);
    for (int t = 0; t < frames; t++) memcpy(r->f + (size_t)t * H, r->b_enc, H * sizeof(float));
    cblas_sgemm(CblasRowMajor, CblasTrans, CblasTrans, frames, H, ENC, 1.0f, encoded, (int)stride, r->w_enc, ENC,
                1.0f, r->f, H);
    r->frames = frames;
    lf_pool_run(&r->pool);
    if (boost) pthread_override_qos_class_end_np(boost);
    return r->n;
}

int lf_rnnt_decode(lf_rnnt *r, const float *encoded, long stride, int frames, int32_t *tokens, int32_t *token_frames,
                   int max) {
    if (frames <= 0) return 0;
    if (stride < frames || max < 0 || r->outputs != r->tokens) return -1;
    r->max = max;
    r->tokens_out = tokens;
    r->token_frames = token_frames;
    return run(r, encoded, stride, frames);
}

int lf_tdt_decode(lf_rnnt *r, const float *encoded, long stride, int frames, int valid, bool last, int32_t *tokens,
                  int32_t *token_frames, int32_t *durations, float *probabilities, int max) {
    if (frames <= 1 || valid <= 0) return 0;   // FluidAudio returns nothing for a single frame
    if (stride < frames || max < 0 || r->outputs == r->tokens) return -1;
    r->valid = valid;
    r->last = last;
    r->max = max;
    r->tokens_out = tokens;
    r->token_frames = token_frames;
    r->durations_out = durations;
    r->probabilities = probabilities;
    return run(r, encoded, stride, frames);
}
