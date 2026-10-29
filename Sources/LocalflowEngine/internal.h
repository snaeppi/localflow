// Shared by the engine, the converter and the RNNT decoder.
#pragma once

#include <arm_neon.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

#define LF_LINE 128   // Apple Silicon cache line

/// Threads that run a job together, one per performance core with the calling thread as thread 0:
/// the cleanup model's passes and the RNNT decoder each have one. A job's parts meet at lf_barrier,
/// and a job ends with one, so lf_pool_run returns when every thread is done. Barriers and the
/// workers between jobs spin for a moment, then sleep.
typedef struct {
    void (*job)(void *ctx, int ith);
    void *ctx;
    int n_threads;
    pthread_t threads[16];
    _Alignas(LF_LINE) _Atomic uint32_t generation;   // +2 per job, odd after lf_pool_prepare
    _Alignas(LF_LINE) _Atomic int sleeping;
    _Alignas(LF_LINE) _Atomic int barrier_count;
    _Alignas(LF_LINE) _Atomic uint32_t barrier_phase;
    _Atomic int barrier_sleeping;
    _Atomic bool quit;
} lf_pool;

/// Starts n_threads - 1 workers (at most 15). False, with none left running, if one can't start.
bool lf_pool_start(lf_pool *pool, int n_threads, void (*job)(void *ctx, int ith), void *ctx);
void lf_pool_stop(lf_pool *pool);
/// Runs the job on every thread, the caller as thread 0.
void lf_pool_run(lf_pool *pool);
/// Wakes the workers to spin for a job that is coming soon, so it doesn't wait for them to wake.
void lf_pool_prepare(lf_pool *pool);
/// Performance cores, at most 16 (4 if unknown).
int lf_performance_cores(void);
/// lf_barrier's waiting, once it has spun for a few hundred rounds.
void lf_barrier_wait(lf_pool *pool, uint32_t phase);
void lf_barrier_release(lf_pool *pool);

static inline void lf_barrier(lf_pool *pool) {
    if (pool->n_threads == 1) return;
    const uint32_t phase = atomic_load_explicit(&pool->barrier_phase, memory_order_relaxed);
    if (atomic_fetch_add_explicit(&pool->barrier_count, 1, memory_order_acq_rel) == pool->n_threads - 1) {
        atomic_store_explicit(&pool->barrier_count, 0, memory_order_relaxed);
        atomic_store(&pool->barrier_phase, phase + 1);
        if (atomic_load(&pool->barrier_sleeping)) lf_barrier_release(pool);
    } else {
        for (int spins = 0; atomic_load_explicit(&pool->barrier_phase, memory_order_acquire) == phase; spins++) {
            if (spins < 512) __builtin_arm_yield();
            else lf_barrier_wait(pool, phase);
        }
    }
}

/// `localflow.format` in converted files; bump it (and the number in `RewriteModel.file`) when the layout
/// or the transform changes, so installed models are downloaded and converted again.
#define LF_FORMAT 2
#define HD 128        // attention head dimension
#define LF_ALIGN 64   // tensor alignment in converted files (one SME vector)

/// Orthonormal Walsh-Hadamard transform in place; n is a power of 2, at least 8.
static inline void lf_fwht(float *x, int n) {
    const uint32x4_t odd = { 0, ~0u, 0, ~0u };
    for (int i = 0; i < n; i += 4) {
        float32x4_t v = vld1q_f32(x + i);
        float32x4_t r = vrev64q_f32(v);                        // b a d c
        v = vbslq_f32(odd, vsubq_f32(r, v), vaddq_f32(v, r));  // a+b a-b c+d c-d
        r = vextq_f32(v, v, 2);
        v = vcombine_f32(vget_low_f32(vaddq_f32(v, r)), vget_high_f32(vsubq_f32(r, v)));
        vst1q_f32(x + i, v);
    }
    for (int len = 4; len < n; len <<= 1)
        for (int i = 0; i < n; i += len << 1)
            for (int j = i; j < i + len; j += 4) {
                const float32x4_t a = vld1q_f32(x + j), b = vld1q_f32(x + j + len);
                vst1q_f32(x + j, vaddq_f32(a, b));
                vst1q_f32(x + j + len, vsubq_f32(a, b));
            }
    const float s = 1.0f / sqrtf((float)n);
    for (int i = 0; i < n; i += 4) vst1q_f32(x + i, vmulq_n_f32(vld1q_f32(x + i), s));
}

/// The FFN hidden state is rotated in blocks of this many values (a power of 2 dividing n_ff).
static inline int lf_ffn_block(int n_ff, int n_embd) {
    int b = n_embd;
    while (b > 8 && n_ff % b) b >>= 1;
    return b;
}
