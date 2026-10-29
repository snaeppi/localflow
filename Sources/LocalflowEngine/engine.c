// The cleanup model's forward pass, written for this one model (Qwen3, ~0.6B) instead of a graph
// of general operations, because each dictation is a few passes of 1–300 tokens where llama.cpp's
// per-node barriers, its one-row-at-a-time leftovers and per-32 scales cost more than the math
// (bench/README.md, "Cleanup engine"). Per layer: RMS norm, Q/K/V as one matrix (with the Q/K norms,
// RoPE and the cache stores done by whoever finishes a head), attention, O, RMS norm, gate/up, the
// FFN hidden state's rotation, down: 8 barriers. Matrices are int8 with one scale per row times
// int8 activations with one scale per token (see convert.c): NEON dot products on every Apple
// Silicon Mac, plus SME outer products on chips that have it.
#include "LocalflowEngine.h"
#include "gguf.h"
#include "internal.h"

#include <arm_sme.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define LINE LF_LINE
#define SME_THREADS 2       // one per P-cluster's SME unit; three or four measured no faster end to end
#ifndef LF_SME
#define LF_SME 1            // 0: NEON only, as on chips before M4 (bench/rewrite_harness, for comparison)
#endif
#define SME_MIN_TOKENS 9    // fewer leave the 16-token tiles mostly empty: NEON alone did 5 tokens in 4.5 ms, not 4.7

/// A matrix of N rows × K: int8 in [N/16][K/4][16 rows][4] (one SME vector per line of 64 bytes;
/// NEON reads quarters of it) and one float scale per row.
typedef struct { const int8_t *q; const float *s; } matrix;

typedef struct {
    matrix wq, wk, wv, wo, wg, wu, wd;
    const float *q_norm, *k_norm;
} layer;

typedef struct { _Alignas(LINE) _Atomic int value; } counter;

struct lf_model {
    void *map;
    size_t map_size;
    int n_embd, n_layer, n_head, n_head_kv, n_ff, n_vocab, n_ctx, n_batch, n_threads, ffn_block;
    int kv_stride;              // positions per head in the caches: n_ctx plus padding for 8-key blocks
    float eps;
    bool sme;
    const __fp16 *embedding;    // rotated
    matrix output;
    layer *layers;
    float *rope_cos, *rope_sin; // [n_ctx][HD/2]

    // vocabulary
    const uint8_t **token_text, **merge_text;
    uint32_t *token_length, *merge_length;
    int32_t *token_type;
    int n_merges;
    int32_t *end_tokens;
    int n_end_tokens;

    // per pass
    __fp16 *kc, *vc;            // [n_layer][n_head_kv][kv_stride][HD]
    float *x;                   // [n_batch][n_embd] residual stream (rotated)
    float *qkv;                 // [n_batch][(n_head + 2 n_head_kv) HD]
    float *attn;                // [n_batch][n_head HD]
    float *h;                   // [n_batch][n_ff]
    int8_t *act[2];             // quantized activations, [tokens/16][K/4][16][4]
    float *act_scale[2];        // per token
    float *scratch;             // per thread
    size_t scratch_floats;
    float *best_value;          // [n_threads][n_batch]
    int32_t *best_token;
    counter *chunks;            // work handed out, per phase
    _Atomic int *heads_done;    // [n_layer][heads] units finished per Q/K/V head
    _Atomic int *tokens_done;   // [n_layer][n_batch] attention items finished per token
    int n_chunks;
    const int32_t *tokens;
    int n, pos, n_out;

    lf_pool pool;
};

// MARK: Vector helpers

static inline float32x4_t v_expf(float32x4_t x) {
    // ggml_v_expf (ARM's optimized routines): max error 1.45 ulp
    const float32x4_t r = vdupq_n_f32(0x1.8p23f);
    const float32x4_t z = vfmaq_f32(r, x, vdupq_n_f32(0x1.715476p+0f));
    const float32x4_t n = vsubq_f32(z, r);
    const float32x4_t b = vfmsq_f32(vfmsq_f32(x, n, vdupq_n_f32(0x1.62e4p-1f)), n, vdupq_n_f32(0x1.7f7d1cp-20f));
    const uint32x4_t e = vshlq_n_u32(vreinterpretq_u32_f32(z), 23);
    const float32x4_t k = vreinterpretq_f32_u32(vaddq_u32(e, vreinterpretq_u32_f32(vdupq_n_f32(1))));
    const uint32x4_t c = vcagtq_f32(n, vdupq_n_f32(126));
    const float32x4_t u = vmulq_f32(b, b);
    const float32x4_t j = vfmaq_f32(
        vmulq_f32(vdupq_n_f32(0x1.ffffecp-1f), b),
        vfmaq_f32(vfmaq_f32(vdupq_n_f32(0x1.fffdb6p-2f), vdupq_n_f32(0x1.555e66p-3f), b),
                  vfmaq_f32(vdupq_n_f32(0x1.573e2ep-5f), vdupq_n_f32(0x1.0e4020p-7f), b), u), u);
    if (!vpaddd_u64(vreinterpretq_u64_u32(c))) return vfmaq_f32(k, j, k);
    const uint32x4_t d = vandq_u32(vclezq_f32(n), vdupq_n_u32(0x82000000));
    const float32x4_t s1 = vreinterpretq_f32_u32(vaddq_u32(d, vdupq_n_u32(0x7f000000)));
    const float32x4_t s2 = vreinterpretq_f32_u32(vsubq_u32(e, d));
    return vbslq_f32(vcagtq_f32(n, vdupq_n_f32(192)), vmulq_f32(s1, s1),
                     vbslq_f32(c, vmulq_f32(vfmaq_f32(s2, s2, j), s1), vfmaq_f32(k, k, j)));
}

static inline float32x4_t v_silu(float32x4_t x) {
    return vdivq_f32(x, vaddq_f32(vdupq_n_f32(1.0f), v_expf(vnegq_f32(x))));
}

/// y = x / rms(x) (· w), as ggml computes it: the sum of squares in double.
static void rms_norm(const float *restrict x, const float *restrict w, float *restrict y, int n, float eps) {
    float64x2_t s0 = vdupq_n_f64(0), s1 = vdupq_n_f64(0);
    for (int i = 0; i < n; i += 4) {
        const float32x4_t v = vld1q_f32(x + i), sq = vmulq_f32(v, v);
        s0 = vaddq_f64(s0, vcvt_f64_f32(vget_low_f32(sq)));
        s1 = vaddq_f64(s1, vcvt_high_f64_f32(sq));
    }
    const float scale = 1.0f / sqrtf((float)(vaddvq_f64(vaddq_f64(s0, s1)) / n) + eps);
    for (int i = 0; i < n; i += 4) {
        const float32x4_t v = vmulq_n_f32(vld1q_f32(x + i), scale);
        vst1q_f32(y + i, w ? vmulq_f32(v, vld1q_f32(w + i)) : v);
    }
}

/// RoPE, NEOX style (pairs i and i + HD/2).
static void rope(float *v, const float *c, const float *s) {
    for (int i = 0; i < HD / 2; i += 4) {
        const float32x4_t x0 = vld1q_f32(v + i), x1 = vld1q_f32(v + i + HD / 2);
        const float32x4_t vc = vld1q_f32(c + i), vs = vld1q_f32(s + i);
        vst1q_f32(v + i, vsubq_f32(vmulq_f32(x0, vc), vmulq_f32(x1, vs)));
        vst1q_f32(v + i + HD / 2, vaddq_f32(vmulq_f32(x0, vs), vmulq_f32(x1, vc)));
    }
}

static void store_f16(__fp16 *dst, const float *src, int n) {
    for (int i = 0; i < n; i += 8)
        vst1q_f16(dst + i, vcombine_f16(vcvt_f16_f32(vld1q_f32(src + i)), vcvt_f16_f32(vld1q_f32(src + i + 4))));
}

static inline void add_rows(float *restrict x, const float *restrict y, int n) {
    for (int i = 0; i < n; i += 4) vst1q_f32(x + i, vaddq_f32(vld1q_f32(x + i), vld1q_f32(y + i)));
}

/// Token j's row as int8 with one scale, into [j/16][K/4][j%16][4].
static void quantize_token(const float *restrict x, int K, int8_t *restrict act, int j, float *restrict scale) {
    float32x4_t amax = vdupq_n_f32(0);
    for (int i = 0; i < K; i += 4) amax = vmaxq_f32(amax, vabsq_f32(vld1q_f32(x + i)));
    const float d = vmaxvq_f32(amax) / 127.0f, id = d ? 1.0f / d : 0.0f;
    *scale = d;
    int8_t *dst = act + (size_t)(j / 16) * 16 * K + 4 * (j % 16);
    for (int g = 0; g < K / 4; g++) {
        const int16x4_t q16 = vmovn_s32(vcvtnq_s32_f32(vmulq_n_f32(vld1q_f32(x + 4 * g), id)));
        const uint32_t word = vget_lane_u32(vreinterpret_u32_s8(vmovn_s16(vcombine_s16(q16, q16))), 0);
        memcpy(dst + 64 * g, &word, 4);
    }
}

// MARK: Matrix kernels

/// 8 rows × T ≤ 8 tokens over all of K: per 4 columns, two weight and two activation loads feed up
/// to 16 independent dot products (a 16 × 4 tile needs five loads for 16).
static inline __attribute__((always_inline)) void kernel8(int K, const int8_t *restrict w, const int8_t *restrict a,
                                                           const int T, int32x4_t o[2][8]) {
    int32x4_t s[2][8];
    for (int i = 0; i < 2; i++) for (int j = 0; j < 8; j++) s[i][j] = vdupq_n_s32(0);
#pragma clang loop unroll_count(2)
    for (int g = 0; g < K / 4; g++) {
        const int8x16_t b0 = vld1q_s8(w + 64 * g), b1 = vld1q_s8(w + 64 * g + 16);
        const int8x16_t a0 = vld1q_s8(a + 64 * g);
        const int8x16_t a1 = T > 4 ? vld1q_s8(a + 64 * g + 16) : a0;
#define TOKEN(j, av, lane) \
        s[0][j] = vdotq_laneq_s32(s[0][j], b0, av, lane); s[1][j] = vdotq_laneq_s32(s[1][j], b1, av, lane);
        TOKEN(0, a0, 0)
        if (T > 1) { TOKEN(1, a0, 1) }
        if (T > 2) { TOKEN(2, a0, 2) }
        if (T > 3) { TOKEN(3, a0, 3) }
        if (T > 4) { TOKEN(4, a1, 0) }
        if (T > 5) { TOKEN(5, a1, 1) }
        if (T > 6) { TOKEN(6, a1, 2) }
        if (T > 7) { TOKEN(7, a1, 3) }
#undef TOKEN
    }
    for (int i = 0; i < 2; i++) for (int j = 0; j < T; j++) o[i][j] = s[i][j];
}

/// out[t * ldo + r] = row r (of nrows, a multiple of 16) · token t, for t < M; NEON.
static void matmul_neon(const int8_t *restrict w, const float *restrict ws, int K, int nrows,
                        const int8_t *restrict act, const float *restrict as, int M, float *restrict out, int ldo) {
    for (int r = 0; r < nrows; r += 8) {
        const int8_t *wr = w + (size_t)(r / 16) * 16 * K + 16 * ((r % 16) / 4);
        const float32x4_t sw0 = vld1q_f32(ws + r), sw1 = vld1q_f32(ws + r + 4);
        for (int t = 0; t < M; t += 8) {
            const int8_t *a = act + (size_t)(t / 16) * 16 * K + 16 * ((t % 16) / 4);
            int32x4_t o[2][8];
            const int T = M - t < 8 ? M - t : 8;
            switch (T) {
            case 1: kernel8(K, wr, a, 1, o); break;
            case 2: kernel8(K, wr, a, 2, o); break;
            case 3: kernel8(K, wr, a, 3, o); break;
            case 4: kernel8(K, wr, a, 4, o); break;
            case 5: kernel8(K, wr, a, 5, o); break;
            case 6: kernel8(K, wr, a, 6, o); break;
            case 7: kernel8(K, wr, a, 7, o); break;
            default: kernel8(K, wr, a, 8, o); break;
            }
            for (int j = 0; j < T; j++) {
                float *dst = out + (size_t)(t + j) * ldo + r;
                vst1q_f32(dst, vmulq_n_f32(vmulq_f32(vcvtq_f32_s32(o[0][j]), sw0), as[t + j]));
                vst1q_f32(dst + 4, vmulq_n_f32(vmulq_f32(vcvtq_f32_s32(o[1][j]), sw1), as[t + j]));
            }
        }
    }
}

/// Column `col` of ZA tile `tile` (one token's 16 rows of int32 sums) as floats, times the rows'
/// scales (ws + rows) and the token's, into dst. A macro because the tile index must be a constant.
#define STORE(tile, col, rows, token_scale, dst) \
    svst1_f32(p32, dst, svmul_n_f32_x(p32, svmul_f32_x(p32, svcvt_f32_s32_x(p32, \
        svread_ver_za32_s32_m(svundef_s32(), p32, tile, col)), svld1_f32(p32, ws + (rows))), token_scale))

/// The same on SME: 64 rows (the four 16 × 16 int32 tiles of ZA) × 16 tokens per sweep over K.
__attribute__((target("sme2"))) __arm_new("za") __arm_locally_streaming
static void matmul_sme(const int8_t *w, const float *ws, int K, int nrows, const int8_t *act, const float *as, int M,
                       float *out, int ldo) {
    const svbool_t p8 = svptrue_b8(), p32 = svptrue_b32();
    const size_t block = (size_t)16 * K;
    // Two token groups at a time where there are: 32 rows × 32 tokens, four loads per four outer
    // products instead of five, and half the weight traffic.
    int t32 = 0;
    for (; t32 + 16 < M; t32 += 32) {
        const int8_t *a0 = act + (size_t)(t32 / 16) * block, *a1 = a0 + block;
        for (int r = 0; r < nrows; r += 32) {
            const int8_t *w0 = w + (size_t)(r / 16) * block, *w1 = w0 + block;
            const bool two = r + 16 < nrows;
            svzero_za();
            for (int k = 0; k < K / 4; k++) {
                const svint8_t av0 = svld1_s8(p8, a0 + 64 * k), av1 = svld1_s8(p8, a1 + 64 * k);
                const svint8_t wv0 = svld1_s8(p8, w0 + 64 * k);
                svmopa_za32_s8_m(0, p8, p8, wv0, av0);
                svmopa_za32_s8_m(2, p8, p8, wv0, av1);
                if (two) {
                    const svint8_t wv1 = svld1_s8(p8, w1 + 64 * k);
                    svmopa_za32_s8_m(1, p8, p8, wv1, av0);
                    svmopa_za32_s8_m(3, p8, p8, wv1, av1);
                }
            }
            const int second = M - t32 - 16 < 16 ? M - t32 - 16 : 16;
            for (int c = 0; c < 16; c++) {
                float *o = out + (size_t)(t32 + c) * ldo + r;
                STORE(0, c, r, as[t32 + c], o);
                if (two) STORE(1, c, r + 16, as[t32 + c], o + 16);
                if (c < second) {
                    o += (size_t)16 * ldo;
                    STORE(2, c, r, as[t32 + 16 + c], o);
                    if (two) STORE(3, c, r + 16, as[t32 + 16 + c], o + 16);
                }
            }
        }
    }
    if (t32 >= M) return;
    act += (size_t)(t32 / 16) * block;
    as += t32;
    out += (size_t)t32 * ldo;
    M -= t32;
    for (int r = 0; r < nrows; r += 64) {
        const int tiles = (nrows - r) / 16 < 4 ? (nrows - r) / 16 : 4;
        const int8_t *w0 = w + (size_t)(r / 16) * block;
        for (int t = 0; t < M; t += 16) {
            const int8_t *a = act + (size_t)(t / 16) * block;
            svzero_za();
            if (tiles == 4) {
                for (int k = 0; k < K / 4; k++) {
                    const svint8_t av = svld1_s8(p8, a + 64 * k);
                    svmopa_za32_s8_m(0, p8, p8, svld1_s8(p8, w0 + 64 * k), av);
                    svmopa_za32_s8_m(1, p8, p8, svld1_s8(p8, w0 + block + 64 * k), av);
                    svmopa_za32_s8_m(2, p8, p8, svld1_s8(p8, w0 + 2 * block + 64 * k), av);
                    svmopa_za32_s8_m(3, p8, p8, svld1_s8(p8, w0 + 3 * block + 64 * k), av);
                }
            } else {
                for (int k = 0; k < K / 4; k++) {
                    const svint8_t av = svld1_s8(p8, a + 64 * k);
                    svmopa_za32_s8_m(0, p8, p8, svld1_s8(p8, w0 + 64 * k), av);
                    if (tiles > 1) svmopa_za32_s8_m(1, p8, p8, svld1_s8(p8, w0 + block + 64 * k), av);
                    if (tiles > 2) svmopa_za32_s8_m(2, p8, p8, svld1_s8(p8, w0 + 2 * block + 64 * k), av);
                }
            }
            const int columns = M - t < 16 ? M - t : 16;
            for (int c = 0; c < columns; c++) {
                float *o = out + (size_t)(t + c) * ldo + r;
                STORE(0, c, r, as[t + c], o);
                if (tiles > 1) STORE(1, c, r + 16, as[t + c], o + 16);
                if (tiles > 2) STORE(2, c, r + 32, as[t + c], o + 32);
                if (tiles > 3) STORE(3, c, r + 48, as[t + c], o + 48);
            }
        }
    }
}

#undef STORE

/// Rows [r0, r0 + nrows) of a K-column matrix times the M tokens of activation buffer `which`.
static void matmul(const lf_model *m, matrix w, int K, int r0, int nrows, int which, int M, float *out, int ldo,
                   bool sme) {
    if (sme) matmul_sme(w.q + (size_t)r0 * K, w.s + r0, K, nrows, m->act[which], m->act_scale[which], M, out, ldo);
    else matmul_neon(w.q + (size_t)r0 * K, w.s + r0, K, nrows, m->act[which], m->act_scale[which], M, out, ldo);
}

// MARK: Attention

/// Attention for the query heads 2g and 2g+1 (sharing key/value head g) and tokens j0..j0+nt-1
/// (nt ≤ 2), so every key and value row loaded serves up to four query rows. Q·K in fp16 (as
/// llama.cpp's CPU flash attention accumulates; int8 here measurably cost accuracy), softmax in
/// fp32, P·V in fp16 flushed to fp32 every 32 keys. out[r] receives row r = token * 2 + head.
static inline __attribute__((always_inline)) void attention_rows(const lf_model *m, int il, int g, int j0, const int nt,
                                                                  float *scratch, float *out[4]) {
    const int R = 2 * nt;
    const int n_kv = m->pos + j0 + nt;   // the later token's keys; the earlier one masks its last key
    const int n4 = (n_kv + 3) & ~3, n8 = (n_kv + 7) & ~7;   // padded keys are read (the cache has room) and masked
    const size_t head = ((size_t)il * m->n_head_kv + g) * m->kv_stride;
    const __fp16 *K = m->kc + head * HD, *V = m->vc + head * HD;
    const int n_qkv = (m->n_head + 2 * m->n_head_kv) * HD;
    const int stride = n8 + 8;
    float *scores = scratch;                              // [R][stride]
    __fp16 *q = (__fp16 *)(scratch + 4 * stride);         // [R][HD]
    __fp16 *p = q + 4 * HD;                               // [R][stride]
    for (int r = 0; r < R; r++) {
        const float *qf = m->qkv + (size_t)(j0 + r / 2) * n_qkv + (size_t)(2 * g + r % 2) * HD;
        for (int i = 0; i < HD; i += 8)
            vst1q_f16(q + r * HD + i,
                      vcombine_f16(vcvt_f16_f32(vld1q_f32(qf + i)), vcvt_f16_f32(vld1q_f32(qf + i + 4))));
    }
    const float scale = 1.0f / sqrtf((float)HD);
    float32x4_t mx[4];
    for (int r = 0; r < 4; r++) mx[r] = vdupq_n_f32(-INFINITY);
    for (int t = 0; t < n4; t += 4) {
        // 4 keys × up to 4 rows: 16 accumulator chains, two loads per four FMAs.
        float16x8_t acc[4][4];
        for (int k = 0; k < 4; k++) for (int r = 0; r < 4; r++) acc[k][r] = vdupq_n_f16(0);
        const __fp16 *kt = K + (size_t)t * HD;
#pragma clang loop unroll(full)
        for (int i = 0; i < HD; i += 8) {
            float16x8_t qv[4];
#pragma clang loop unroll(full)
            for (int r = 0; r < R; r++) qv[r] = vld1q_f16(q + r * HD + i);
            for (int k = 0; k < 4; k++) {
                const float16x8_t kv = vld1q_f16(kt + (size_t)k * HD + i);
                for (int r = 0; r < R; r++) acc[k][r] = vfmaq_f16(acc[k][r], kv, qv[r]);
            }
        }
        for (int r = 0; r < R; r += 2) {
            // Pairwise sums: the 8 lanes are 4 keys × these two rows.
            const float16x8_t row0 = vpaddq_f16(vpaddq_f16(acc[0][r], acc[1][r]), vpaddq_f16(acc[2][r], acc[3][r]));
            const float16x8_t row1 = vpaddq_f16(vpaddq_f16(acc[0][r + 1], acc[1][r + 1]),
                                                vpaddq_f16(acc[2][r + 1], acc[3][r + 1]));
            const float16x8_t sum = vpaddq_f16(row0, row1);
            float32x4_t v[2] = { vmulq_n_f32(vcvt_f32_f16(vget_low_f16(sum)), scale),
                                 vmulq_n_f32(vcvt_high_f32_f16(sum), scale) };
            const int limit = n_kv - (nt - 1 - r / 2);   // keys this token may see
            if (t + 4 > limit) {
                const uint32_t visible = (uint32_t)(limit > t ? limit - t : 0);
                const uint32x4_t keep = vcltq_u32((uint32x4_t){ 0, 1, 2, 3 }, vdupq_n_u32(visible));
                v[0] = vbslq_f32(keep, v[0], vdupq_n_f32(-INFINITY));
                v[1] = vbslq_f32(keep, v[1], vdupq_n_f32(-INFINITY));
            }
            for (int h = 0; h < 2; h++) {
                vst1q_f32(scores + (r + h) * stride + t, v[h]);
                mx[r + h] = vmaxq_f32(mx[r + h], v[h]);
            }
        }
    }
    float inv[4];
    for (int r = 0; r < R; r++) {
        const float32x4_t top = vdupq_n_f32(vmaxvq_f32(mx[r]));
        float32x4_t sum = vdupq_n_f32(0);
        float *sr = scores + r * stride;
        __fp16 *pr = p + r * stride;
        for (int t = 0; t < n4; t += 4) {
            const float32x4_t e = v_expf(vsubq_f32(vld1q_f32(sr + t), top));
            sum = vaddq_f32(sum, e);
            vst1_f16(pr + t, vcvt_f16_f32(e));
        }
        if (n4 < n8) vst1_f16(pr + n4, vdup_n_f16(0));
        inv[r] = 1.0f / vaddvq_f32(sum);
    }
    // P·V in quarters of the head dimension: 4 rows × 4 vectors = 16 accumulators per key.
    for (int quarter = 0; quarter < 4; quarter++) {
        float32x4_t f[4][8];
        for (int r = 0; r < 4; r++) for (int i = 0; i < 8; i++) f[r][i] = vdupq_n_f32(0);
        for (int t0 = 0; t0 < n8; t0 += 32) {
            float16x8_t hacc[4][4];
            for (int r = 0; r < 4; r++) for (int i = 0; i < 4; i++) hacc[r][i] = vdupq_n_f16(0);
            const int t1 = t0 + 32 < n8 ? t0 + 32 : n8;
            for (int t = t0; t < t1; t += 8) {
                float16x8_t pv[4];
                for (int r = 0; r < R; r++) pv[r] = vld1q_f16(p + r * stride + t);
#define KEY(l) { \
                    const __fp16 *vt = V + (size_t)(t + l) * HD + quarter * 32; \
                    for (int i = 0; i < 4; i++) { \
                        const float16x8_t vv = vld1q_f16(vt + 8 * i); \
                        for (int r = 0; r < R; r++) hacc[r][i] = vfmaq_laneq_f16(hacc[r][i], vv, pv[r], l); \
                    } }
                KEY(0) KEY(1) KEY(2) KEY(3) KEY(4) KEY(5) KEY(6) KEY(7)
#undef KEY
            }
            for (int r = 0; r < R; r++)
                for (int i = 0; i < 4; i++) {
                    f[r][2 * i] = vaddq_f32(f[r][2 * i], vcvt_f32_f16(vget_low_f16(hacc[r][i])));
                    f[r][2 * i + 1] = vaddq_f32(f[r][2 * i + 1], vcvt_high_f32_f16(hacc[r][i]));
                }
        }
        for (int r = 0; r < R; r++)
            for (int i = 0; i < 8; i++) vst1q_f32(out[r] + quarter * 32 + 4 * i, vmulq_n_f32(f[r][i], inv[r]));
    }
}

static void attention(const lf_model *m, int il, int g, int j0, int nt, float *scratch, float *out[4]) {
    if (nt == 2) attention_rows(m, il, g, j0, 2, scratch, out);
    else attention_rows(m, il, g, j0, 1, scratch, out);
}

// MARK: Pass

static void barrier(lf_model *m) { lf_barrier(&m->pool); }

/// Guided self-scheduling: hands out [*first, *first + n) of `total` units, big pieces first (long
/// runs for the prefetchers) and single units at the end (short tails at the barrier).
static int grab(lf_model *m, int phase, int total, int max, int min, int *first) {
    _Atomic int *c = &m->chunks[phase].value;
    int cur = atomic_load_explicit(c, memory_order_relaxed);
    for (;;) {
        if (cur >= total) return 0;
        int n = (total - cur) / (2 * m->n_threads);
        if (n > max) n = max;
        if (n < min) n = min;
        if (n > total - cur) n = total - cur;
        if (atomic_compare_exchange_weak_explicit(c, &cur, cur + n, memory_order_relaxed, memory_order_relaxed)) {
            *first = cur;
            return n;
        }
    }
}

/// Q/K norm and RoPE for a finished query or key head, and the key and value caches, for every token.
static void finish_head(lf_model *m, const layer *ly, int il, int head, int M) {
    const int n_qkv = (m->n_head + 2 * m->n_head_kv) * HD;
    for (int j = 0; j < M; j++) {
        float *v = m->qkv + (size_t)j * n_qkv + (size_t)head * HD;
        const int p = m->pos + j;
        if (head >= m->n_head + m->n_head_kv) {
            const int g = head - m->n_head - m->n_head_kv;
            store_f16(m->vc + (((size_t)il * m->n_head_kv + g) * m->kv_stride + p) * HD, v, HD);
            continue;
        }
        const bool query = head < m->n_head;
        rms_norm(v, query ? ly->q_norm : ly->k_norm, v, HD, m->eps);
        rope(v, m->rope_cos + (size_t)p * (HD / 2), m->rope_sin + (size_t)p * (HD / 2));
        if (!query) {
            const int g = head - m->n_head;
            store_f16(m->kc + (((size_t)il * m->n_head_kv + g) * m->kv_stride + p) * HD, v, HD);
        }
    }
}

static void pass(lf_model *m, int ith) {
    // Read the pass's parameters before the first barrier: once the last barrier is passed, the
    // caller may already be setting up the next pass, and a thread that read n_out late would run
    // that pass's output layer here and fall out of step with the others for good.
    const int nth = m->n_threads, E = m->n_embd, M = m->n, L = m->n_layer, n_out = m->n_out;
    const int nQ = m->n_head * HD, nKV = m->n_head_kv * HD, nQKV = nQ + 2 * nKV, heads = nQKV / HD;
    float *scratch = m->scratch + (size_t)ith * m->scratch_floats;
    // Units of 16 rows whose outputs for all tokens fit in this thread's scratch.
    const int cap = (int)(m->scratch_floats / (16 * (size_t)M));
    // The last threads drive the SME units on passes big enough to fill their tiles.
    const bool sme = m->sme && ith >= nth - SME_THREADS && M >= SME_MIN_TOKENS;
    const bool sme_out = m->sme && ith >= nth - SME_THREADS && n_out >= SME_MIN_TOKENS;
    // SME threads take at least 64 rows at a time, so all four of its tiles have work.
    const int units = sme ? (cap / 2 < 4 ? (cap / 2 > 0 ? cap / 2 : 1) : 4) : 1;
    int phase = 0, u0, n;

    for (int j = ith; j < M; j += nth) {
        const __fp16 *row = m->embedding + (size_t)m->tokens[j] * E;
        float *x = m->x + (size_t)j * E;
        for (int i = 0; i < E; i += 8) {
            const float16x8_t v = vld1q_f16(row + i);
            vst1q_f32(x + i, vcvt_f32_f16(vget_low_f16(v)));
            vst1q_f32(x + i + 4, vcvt_high_f32_f16(v));
        }
    }
    barrier(m);

    for (int il = 0; il < L; il++) {
        const layer *ly = &m->layers[il];
        // After the last layer's attention only the tokens whose next token is wanted matter.
        const int m0 = il == L - 1 ? M - n_out : 0, mc = M - m0;
        _Atomic int *heads_done = m->heads_done + (size_t)il * heads;
        _Atomic int *tokens_done = m->tokens_done + (size_t)il * m->n_batch;

        for (int j = ith; j < M; j += nth) {
            rms_norm(m->x + (size_t)j * E, NULL, scratch, E, m->eps);
            quantize_token(scratch, E, m->act[0], j, &m->act_scale[0][j]);
        }
        barrier(m);

        // Q, K and V as one matrix, in units of 16 rows; whoever completes a head finishes it.
        while ((n = grab(m, phase, nQKV / 16, nQKV / 16, units, &u0))) {
            for (int r = u0 * 16, end = (u0 + n) * 16; r < end;) {
                const matrix w = r < nQ ? ly->wq : r < nQ + nKV ? ly->wk : ly->wv;
                const int base = r < nQ ? 0 : r < nQ + nKV ? nQ : nQ + nKV;
                const int stop = base + (r < nQ ? nQ : nKV) < end ? base + (r < nQ ? nQ : nKV) : end;
                matmul(m, w, E, r - base, stop - r, 0, M, m->qkv + r, nQKV, sme);
                r = stop;
            }
            for (int h = u0 * 16 / HD; h <= ((u0 + n) * 16 - 1) / HD; h++) {
                const int lo = u0 * 16 > h * HD ? u0 * 16 : h * HD;
                const int hi = (u0 + n) * 16 < (h + 1) * HD ? (u0 + n) * 16 : (h + 1) * HD;
                const int units = (hi - lo) / 16;
                if (atomic_fetch_add_explicit(&heads_done[h], units, memory_order_acq_rel) + units == HD / 16)
                    finish_head(m, ly, il, h, M);
            }
        }
        phase++;
        barrier(m);
        if (mc == 0) continue;

        // Attention per key/value head and pair of tokens; consecutive items are consecutive tokens
        // of one head, so its keys and values stay in L1. Whoever completes a token quantizes its row.
        const int pairs = (mc + 1) / 2;
        while ((n = grab(m, phase, m->n_head_kv * pairs, 4, 1, &u0)))
            for (int c = u0; c < u0 + n; c++) {
                const int g = c / pairs, j = m0 + 2 * (c % pairs), nt = m0 + mc - j < 2 ? 1 : 2;
                float *rows[4];
                for (int r = 0; r < 2 * nt; r++)
                    rows[r] = m->attn + (size_t)(j - m0 + r / 2) * nQ + (size_t)(2 * g + r % 2) * HD;
                attention(m, il, g, j, nt, scratch, rows);
                for (int k = j - m0; k < j - m0 + nt; k++)
                    if (atomic_fetch_add_explicit(&tokens_done[k], 1, memory_order_acq_rel) + 1 == m->n_head_kv)
                        quantize_token(m->attn + (size_t)k * nQ, nQ, m->act[1], k, &m->act_scale[1][k]);
            }
        phase++;
        barrier(m);

        while ((n = grab(m, phase, E / 16, cap, units, &u0))) {
            matmul(m, ly->wo, nQ, u0 * 16, n * 16, 1, mc, scratch, n * 16, sme);
            for (int j = 0; j < mc; j++)
                add_rows(m->x + (size_t)(m0 + j) * E + u0 * 16, scratch + (size_t)j * n * 16, n * 16);
        }
        phase++;
        barrier(m);

        for (int j = ith; j < mc; j += nth) {
            rms_norm(m->x + (size_t)(m0 + j) * E, NULL, scratch, E, m->eps);
            quantize_token(scratch, E, m->act[0], j, &m->act_scale[0][j]);
        }
        barrier(m);

        while ((n = grab(m, phase, m->n_ff / 16, cap / 2, units, &u0))) {
            float *g = scratch, *u = scratch + (size_t)n * 16 * mc;
            matmul(m, ly->wg, E, u0 * 16, n * 16, 0, mc, g, n * 16, sme);
            matmul(m, ly->wu, E, u0 * 16, n * 16, 0, mc, u, n * 16, sme);
            for (int j = 0; j < mc; j++) {
                const float *gj = g + (size_t)j * n * 16, *uj = u + (size_t)j * n * 16;
                float *hj = m->h + (size_t)j * m->n_ff + u0 * 16;
                for (int i = 0; i < n * 16; i += 4)
                    vst1q_f32(hj + i, vmulq_f32(v_silu(vld1q_f32(gj + i)), vld1q_f32(uj + i)));
            }
        }
        phase++;
        barrier(m);

        // The hidden state's rotation (the down matrix holds its inverse), then its quantization.
        for (int j = ith; j < mc; j += nth) {
            float *hj = m->h + (size_t)j * m->n_ff;
            for (int b = 0; b < m->n_ff; b += m->ffn_block) lf_fwht(hj + b, m->ffn_block);
            quantize_token(hj, m->n_ff, m->act[1], j, &m->act_scale[1][j]);
        }
        barrier(m);

        while ((n = grab(m, phase, E / 16, cap, units, &u0))) {
            matmul(m, ly->wd, m->n_ff, u0 * 16, n * 16, 1, mc, scratch, n * 16, sme);
            for (int j = 0; j < mc; j++)
                add_rows(m->x + (size_t)(m0 + j) * E + u0 * 16, scratch + (size_t)j * n * 16, n * 16);
        }
        phase++;
        barrier(m);
    }

    if (n_out == 0) return;
    const int m0 = M - n_out;
    for (int j = ith; j < n_out; j += nth) {
        rms_norm(m->x + (size_t)(m0 + j) * E, NULL, scratch, E, m->eps);
        quantize_token(scratch, E, m->act[0], j, &m->act_scale[0][j]);
    }
    barrier(m);

    // The output layer in units of 16 rows; each thread keeps its best token per position, in row order.
    float *best_value = m->best_value + (size_t)ith * m->n_batch;
    int32_t *best_token = m->best_token + (size_t)ith * m->n_batch;
    for (int j = 0; j < n_out; j++) {
        best_value[j] = -INFINITY;
        best_token[j] = 0;
    }
    const int max_units = (int)(m->scratch_floats / (16 * (size_t)n_out));
    while ((n = grab(m, phase, m->n_vocab / 16, m->n_vocab / 16, sme_out ? 4 : 1, &u0))) {
        for (int k = 0; k < n; k += max_units) {
            const int units = n - k < max_units ? n - k : max_units, r0 = (u0 + k) * 16, nr = units * 16;
            matmul(m, m->output, E, r0, nr, 0, n_out, scratch, nr, sme_out);
            for (int j = 0; j < n_out; j++) {
                const float *l = scratch + (size_t)j * nr;
                float best = best_value[j];
                int32_t token = best_token[j];
                for (int i = 0; i < nr; i++)
                    if (l[i] > best) {
                        best = l[i];
                        token = r0 + i;
                    }
                best_value[j] = best;
                best_token[j] = token;
            }
        }
    }
    barrier(m);
}

// MARK: Threads

static void pass_job(void *m, int ith) { pass(m, ith); }

static void run(lf_model *m) {
    for (int i = 0; i < m->n_chunks; i++) atomic_store_explicit(&m->chunks[i].value, 0, memory_order_relaxed);
    const int heads = m->n_head + 2 * m->n_head_kv;
    for (int i = 0; i < m->n_layer * heads; i++) atomic_store_explicit(&m->heads_done[i], 0, memory_order_relaxed);
    for (int il = 0; il < m->n_layer; il++)
        for (int j = 0; j < m->n; j++)
            atomic_store_explicit(&m->tokens_done[(size_t)il * m->n_batch + j], 0, memory_order_relaxed);
    lf_pool_run(&m->pool);
}

int lf_decode(lf_model *m, const int32_t *tokens, int n, int pos, int n_out, int32_t *argmax) {
    if (n <= 0 || pos < 0 || n_out < 0 || n_out > n || n_out > m->n_batch || pos + n > m->n_ctx) return -1;
    for (int i = 0; i < n; i++)
        if (tokens[i] < 0 || tokens[i] >= m->n_vocab) return -1;
    // The calling thread is one of the workers: every barrier waits for it, so it must not run at
    // a lower priority (or on an efficiency core) than the others.
    pthread_override_t boost = pthread_override_qos_class_start_np(pthread_self(), QOS_CLASS_USER_INTERACTIVE, 0);
    for (int start = 0; start < n;) {
        int end = start + m->n_batch < n ? start + m->n_batch : n;
        // Only the last batch's outputs survive, so it has to hold all of them.
        if (end < n && end > n - n_out) end = n - n_out;
        m->tokens = tokens + start;
        m->n = end - start;
        m->pos = pos + start;
        m->n_out = end == n ? n_out : 0;
        run(m);
        start = end;
    }
    if (boost) pthread_override_qos_class_end_np(boost);
    for (int j = 0; j < n_out; j++) {
        float best = -INFINITY;
        int32_t token = 0;
        for (int t = 0; t < m->n_threads; t++) {
            const float v = m->best_value[(size_t)t * m->n_batch + j];
            const int32_t i = m->best_token[(size_t)t * m->n_batch + j];
            if (v > best || (v == best && i < token)) {
                best = v;
                token = i;
            }
        }
        argmax[j] = token;
    }
    return 0;
}

// MARK: Vocabulary

int lf_vocab_size(const lf_model *m) { return m->n_vocab; }

const char *lf_token_text(const lf_model *m, int token, size_t *length) {
    if (token < 0 || token >= m->n_vocab) { *length = 0; return ""; }
    *length = m->token_length[token];
    return (const char *)m->token_text[token];
}

int32_t lf_token_type(const lf_model *m, int token) {
    return token >= 0 && token < m->n_vocab ? m->token_type[token] : 0;
}

int lf_merge_count(const lf_model *m) { return m->n_merges; }

const char *lf_merge(const lf_model *m, int index, size_t *length) {
    if (index < 0 || index >= m->n_merges) { *length = 0; return ""; }
    *length = m->merge_length[index];
    return (const char *)m->merge_text[index];
}

bool lf_is_end(const lf_model *m, int32_t token) {
    for (int i = 0; i < m->n_end_tokens; i++)
        if (m->end_tokens[i] == token) return true;
    return false;
}

/// Offsets of the strings of a GGUF string array, checked against the end of the file.
static bool index_strings(const gguf *g, const char *key, int count, const uint8_t **text, uint32_t *length) {
    uint32_t type;
    uint64_t n;
    const uint8_t *p;
    if (!gguf_array(g, key, &type, &n, &p) || type != GGUF_TYPE_STRING || n != (uint64_t)count) return false;
    const uint8_t *end = g->base + g->size;
    for (int i = 0; i < count; i++) {
        uint64_t len;
        if (end - p < 8) return false;
        memcpy(&len, p, 8);
        if (len > (uint64_t)(end - p - 8)) return false;
        text[i] = p + 8;
        length[i] = (uint32_t)len;
        p += 8 + len;
    }
    return true;
}

// MARK: Loading

/// Zeroed memory, cache-line aligned. Large blocks come from calloc, which maps fresh zero pages,
/// so only the parts a pass touches (the tokens it has) become resident.
static void *zeroed(size_t bytes) {
    if (bytes >= 1 << 20) return calloc(1, bytes);   // page-aligned at this size
    void *p = NULL;
    if (posix_memalign(&p, LINE, bytes ? bytes : LINE)) return NULL;
    memset(p, 0, bytes);
    return p;
}

void lf_free(lf_model *m) {
    if (!m) return;
    lf_pool_stop(&m->pool);
    if (m->map) munmap(m->map, m->map_size);
    if (m->kc) munmap(m->kc, (size_t)m->n_layer * m->n_head_kv * m->kv_stride * HD * sizeof(__fp16) * 2);
    free(m->layers);
    free(m->rope_cos);
    free(m->rope_sin);
    free(m->token_text);
    free(m->token_length);
    free(m->token_type);
    free(m->merge_text);
    free(m->merge_length);
    free(m->end_tokens);
    free(m->x);
    free(m->qkv);
    free(m->attn);
    free(m->h);
    free(m->act[0]);
    free(m->act[1]);
    free(m->act_scale[0]);
    free(m->act_scale[1]);
    free(m->scratch);
    free(m->best_value);
    free(m->best_token);
    free(m->chunks);
    free((void *)m->heads_done);
    free((void *)m->tokens_done);
    free(m);
}

static bool load_matrix(const gguf *g, const char *name, int K, int N, matrix *out) {
    char scale[80];
    const size_t len = strlen(name);
    if (len < 7 || len + 1 > sizeof scale) return false;
    memcpy(scale, name, len - 6);   // "….weight" → "….scale"
    memcpy(scale + len - 6, "scale", 6);
    out->q = gguf_tensor_data(g, name, TENSOR_I8, K, N);
    out->s = gguf_tensor_data(g, scale, TENSOR_F32, N, 1);
    return out->q && out->s;
}

lf_model *lf_load(const char *path, int n_ctx, int n_batch) {
    if (n_ctx < 1 || n_batch < 1) return NULL;
    lf_model *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->n_ctx = n_ctx;
    m->n_batch = n_batch;
    m->n_threads = lf_performance_cores();
    int sme = 0;
    size_t size = sizeof sme;
    m->sme = LF_SME && sysctlbyname("hw.optional.arm.FEAT_SME2", &sme, &size, NULL, 0) == 0 && sme &&
             m->n_threads > SME_THREADS;

    const int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        free(m);
        return NULL;
    }
    m->map_size = (size_t)st.st_size;
    m->map = mmap(NULL, m->map_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (m->map == MAP_FAILED) {
        m->map = NULL;
        lf_free(m);
        return NULL;
    }
    gguf g;
    if (!gguf_open(&g, m->map, m->map_size)) {
        lf_free(m);
        return NULL;
    }
    double format = 0, layers = 0, embd = 0, ff = 0, heads = 0, heads_kv = 0, rope_base = 0, eps = 0, block = 0;
    gguf_number(&g, "localflow.format", &format);
    gguf_number(&g, "qwen3.block_count", &layers);
    gguf_number(&g, "qwen3.embedding_length", &embd);
    gguf_number(&g, "qwen3.feed_forward_length", &ff);
    gguf_number(&g, "qwen3.attention.head_count", &heads);
    gguf_number(&g, "qwen3.attention.head_count_kv", &heads_kv);
    gguf_number(&g, "qwen3.rope.freq_base", &rope_base);
    gguf_number(&g, "qwen3.attention.layer_norm_rms_epsilon", &eps);
    gguf_number(&g, "localflow.ffn_rotation_block", &block);
    m->n_layer = (int)layers;
    m->n_embd = (int)embd;
    m->n_ff = (int)ff;
    m->n_head = (int)heads;
    m->n_head_kv = (int)heads_kv;
    m->eps = (float)eps;
    m->ffn_block = (int)block;
    uint32_t type;
    uint64_t vocab = 0, merges = 0, ends = 0;
    const uint8_t *items, *end_items = NULL;
    if (gguf_array(&g, "tokenizer.ggml.tokens", &type, &vocab, &items)) m->n_vocab = (int)vocab;
    if (gguf_array(&g, "tokenizer.ggml.merges", &type, &merges, &items)) m->n_merges = (int)merges;
    const bool shape_ok = gguf_array(&g, "localflow.end_tokens", &type, &ends, &end_items) && type == 5 && ends < 64;
    const int E = m->n_embd, Q = m->n_head * HD, KV = m->n_head_kv * HD, F = m->n_ff;
    bool ok = format == LF_FORMAT && shape_ok && m->n_layer > 0 && E >= 256 && E % 16 == 0 &&
              m->n_head == 2 * m->n_head_kv && F % 16 == 0 && m->ffn_block >= 8 && F % m->ffn_block == 0 &&
              m->n_vocab > 0 && m->n_vocab % 16 == 0;
    ok = ok && (m->embedding = gguf_tensor_data(&g, "token_embd.weight", TENSOR_F16, E, m->n_vocab)) != NULL;
    ok = ok && load_matrix(&g, "output.weight", E, m->n_vocab, &m->output);
    m->layers = ok ? calloc(m->n_layer, sizeof(layer)) : NULL;
    ok = ok && m->layers;
    for (int il = 0; ok && il < m->n_layer; il++) {
        layer *ly = &m->layers[il];
        char name[64];
#define MATRIX(field, suffix, K, N) \
        snprintf(name, sizeof name, "blk.%d.%s.weight", il, suffix); \
        ok = ok && load_matrix(&g, name, K, N, &ly->field);
        MATRIX(wq, "attn_q", E, Q)
        MATRIX(wk, "attn_k", E, KV)
        MATRIX(wv, "attn_v", E, KV)
        MATRIX(wo, "attn_output", Q, E)
        MATRIX(wg, "ffn_gate", E, F)
        MATRIX(wu, "ffn_up", E, F)
        MATRIX(wd, "ffn_down", F, E)
#undef MATRIX
        snprintf(name, sizeof name, "blk.%d.attn_q_norm.weight", il);
        ok = ok && (ly->q_norm = gguf_tensor_data(&g, name, TENSOR_F32, HD, 1)) != NULL;
        snprintf(name, sizeof name, "blk.%d.attn_k_norm.weight", il);
        ok = ok && (ly->k_norm = gguf_tensor_data(&g, name, TENSOR_F32, HD, 1)) != NULL;
    }
    if (ok) {
        m->token_text = calloc(m->n_vocab, sizeof *m->token_text);
        m->token_length = calloc(m->n_vocab, sizeof *m->token_length);
        m->token_type = calloc(m->n_vocab, sizeof *m->token_type);
        m->merge_text = calloc(m->n_merges ? m->n_merges : 1, sizeof *m->merge_text);
        m->merge_length = calloc(m->n_merges ? m->n_merges : 1, sizeof *m->merge_length);
        m->end_tokens = calloc(64, sizeof *m->end_tokens);
        uint64_t n_types;
        const uint8_t *types;
        ok = m->token_text && m->token_length && m->token_type && m->merge_text && m->merge_length && m->end_tokens &&
             index_strings(&g, "tokenizer.ggml.tokens", m->n_vocab, m->token_text, m->token_length) &&
             index_strings(&g, "tokenizer.ggml.merges", m->n_merges, m->merge_text, m->merge_length) &&
             gguf_array(&g, "tokenizer.ggml.token_type", &type, &n_types, &types) && type == 5 &&
             n_types == (uint64_t)m->n_vocab &&
             m->map_size - (size_t)(types - (const uint8_t *)m->map) >= n_types * 4;
        if (ok) {
            memcpy(m->token_type, types, n_types * 4);
            memcpy(m->end_tokens, end_items, ends * 4);
            m->n_end_tokens = (int)ends;
        }
    }
    gguf_close(&g);
    if (!ok) {
        lf_free(m);
        return NULL;
    }
    // Read the matrices ahead (after a restart they're on disk): the load happens while the user
    // speaks, and the output layer isn't touched until the first dictation. The embedding table is
    // read a row per token, so it's left to page in on demand.
    const uintptr_t page = (uintptr_t)getpagesize();
    const uintptr_t start = (uintptr_t)m->output.q & ~(page - 1), end = (uintptr_t)m->map + m->map_size;
    if (start < end) madvise((void *)start, end - start, MADV_WILLNEED);

    // RoPE angles exactly as ggml_rope_cache_init computes them (theta multiplied step by step).
    m->rope_cos = zeroed((size_t)n_ctx * HD / 2 * sizeof(float));
    m->rope_sin = zeroed((size_t)n_ctx * HD / 2 * sizeof(float));
    const float theta_scale = powf((float)rope_base, -2.0f / HD);
    for (int p = 0; p < n_ctx && m->rope_cos && m->rope_sin; p++) {
        float theta = (float)p;
        for (int i = 0; i < HD / 2; i++) {
            m->rope_cos[(size_t)p * HD / 2 + i] = cosf(theta);
            m->rope_sin[(size_t)p * HD / 2 + i] = sinf(theta);
            theta *= theta_scale;
        }
    }
    // The caches as anonymous memory: only the positions used get pages.
    m->kv_stride = n_ctx + 8;
    const size_t kv_bytes = (size_t)m->n_layer * m->n_head_kv * m->kv_stride * HD * sizeof(__fp16);
    void *kv = mmap(NULL, kv_bytes * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (kv != MAP_FAILED) {
        m->kc = kv;
        m->vc = (__fp16 *)((char *)kv + kv_bytes);
    }
    const size_t tokens16 = (size_t)(n_batch + 15) / 16 * 16, k_max = (size_t)(Q > F ? Q : F);
    m->x = zeroed(tokens16 * E * sizeof(float));
    m->qkv = zeroed(tokens16 * (Q + 2 * KV) * sizeof(float));
    m->attn = zeroed(tokens16 * Q * sizeof(float));
    m->h = zeroed(tokens16 * F * sizeof(float));
    m->act[0] = zeroed(tokens16 * E);
    m->act[1] = zeroed(tokens16 * k_max);
    m->act_scale[0] = zeroed(tokens16 * sizeof(float));
    m->act_scale[1] = zeroed(tokens16 * sizeof(float));
    // Per thread: matmul outputs for a chunk of rows (at least a unit of 16 for every token), and
    // attention's scores, probabilities and queries.
    const size_t matmul_floats = (size_t)2 * 16 * tokens16 > 65536 ? (size_t)2 * 16 * tokens16 : 65536;
    const size_t attention_floats = (size_t)6 * (n_ctx + 16) + 2 * HD + 64;
    m->scratch_floats = ((matmul_floats > attention_floats ? matmul_floats : attention_floats) + 31) & ~(size_t)31;
    m->scratch = zeroed(m->scratch_floats * m->n_threads * sizeof(float));
    m->best_value = zeroed((size_t)m->n_threads * n_batch * sizeof(float));
    m->best_token = zeroed((size_t)m->n_threads * n_batch * sizeof(int32_t));
    m->n_chunks = 5 * m->n_layer + 1;
    m->chunks = zeroed((size_t)m->n_chunks * sizeof(counter));
    m->heads_done = zeroed((size_t)m->n_layer * (m->n_head + 2 * m->n_head_kv) * sizeof(int));
    m->tokens_done = zeroed((size_t)m->n_layer * n_batch * sizeof(int));
    if (!m->rope_cos || !m->rope_sin || !m->kc || !m->x || !m->qkv || !m->attn || !m->h || !m->act[0] || !m->act[1] ||
        !m->act_scale[0] || !m->act_scale[1] || !m->scratch || !m->best_value || !m->best_token || !m->chunks ||
        !m->heads_done || !m->tokens_done) {
        lf_free(m);
        return NULL;
    }
    if (!lf_pool_start(&m->pool, m->n_threads, pass_job, m)) {
        lf_free(m);
        return NULL;
    }
    return m;
}
