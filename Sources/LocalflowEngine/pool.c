// The engine's worker threads (internal.h). Persistent threads that spin while work is near rather
// than GCD: a pass or a decode is a few milliseconds of work split by barriers every few microseconds.
#include "internal.h"

#include <mach/thread_switch.h>
#include <os/os_sync_wait_on_address.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <time.h>

#define SPIN_NS 200000          // workers spin this long for the next job (passes come ~50 µs apart) before sleeping
#define PREPARE_NS 150000000    // after lf_pool_prepare: the speech model's encoder takes ~30–60 ms
#define BARRIER_SPIN_NS 200000  // at a barrier, before sleeping: under load 50 µs and 1 ms did worse

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

typedef struct { lf_pool *pool; int ith; } worker_start;

static void *worker(void *p) {
    const worker_start start = *(worker_start *)p;
    free(p);
    lf_pool *pool = start.pool;
    uint32_t seen = 0;
    uint64_t spin = SPIN_NS;
    for (;;) {
        uint64_t since = now_ns();
        uint32_t g;
        int spins = 0;
        while ((g = atomic_load_explicit(&pool->generation, memory_order_acquire)) == seen) {
            if (spin == PREPARE_NS && now_ns() - since < spin) {
                // Waiting this long on busy cores would cost these threads their priority (the
                // scheduler's decay of busy threads), and then the job's barriers wait for whichever
                // was preempted: let other threads run first, for up to 1 ms at a time.
                thread_switch(MACH_PORT_NULL, SWITCH_OPTION_DEPRESS, 1);
                continue;
            }
            if ((++spins & 255) || now_ns() - since < spin) {
                __builtin_arm_yield();
                continue;
            }
            atomic_fetch_add(&pool->sleeping, 1);
            if (atomic_load(&pool->generation) == seen)
                os_sync_wait_on_address(&pool->generation, seen, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
            atomic_fetch_sub(&pool->sleeping, 1);
            since = now_ns();
            spin = SPIN_NS;
        }
        seen = g;
        if (atomic_load(&pool->quit)) return NULL;
        if (g & 1) {   // lf_pool_prepare: spin for the job instead
            spin = PREPARE_NS;
            continue;
        }
        spin = SPIN_NS;
        pool->job(pool->ctx, start.ith);
    }
}

static void wake(lf_pool *pool, uint32_t step) {
    atomic_fetch_add(&pool->generation, step);
    if (atomic_load(&pool->sleeping)) os_sync_wake_by_address_all(&pool->generation, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

bool lf_pool_start(lf_pool *pool, int n_threads, void (*job)(void *ctx, int ith), void *ctx) {
    pool->job = job;
    pool->ctx = ctx;
    pool->n_threads = 1;
    if (n_threads > 16) n_threads = 16;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    for (int i = 1; i < n_threads; i++) {
        worker_start *start = malloc(sizeof *start);
        if (start) *start = (worker_start){ pool, i };
        if (!start || pthread_create(&pool->threads[i], &attr, worker, start) != 0) {
            free(start);
            pthread_attr_destroy(&attr);
            lf_pool_stop(pool);
            return false;
        }
        pool->n_threads = i + 1;
    }
    pthread_attr_destroy(&attr);
    return true;
}

void lf_pool_stop(lf_pool *pool) {
    if (pool->n_threads <= 1) return;
    atomic_store(&pool->quit, true);
    atomic_fetch_add(&pool->generation, 2);
    os_sync_wake_by_address_all(&pool->generation, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    for (int i = 1; i < pool->n_threads; i++) pthread_join(pool->threads[i], NULL);
    pool->n_threads = 1;
}

// A barrier normally completes within a few µs. Waiting longer means a thread was preempted (other
// processes keep the cores busy): spinning on would keep it from a core and cost these threads their
// priority (the scheduler's decay of busy threads), so the next barriers would wait too. Measured
// with every core busy: cleanup p90 604 ms, decoder p50 180 ms with spinning only.
void lf_barrier_wait(lf_pool *pool, uint32_t phase) {
    const uint64_t since = now_ns();
    while (atomic_load_explicit(&pool->barrier_phase, memory_order_acquire) == phase) {
        if (now_ns() - since < BARRIER_SPIN_NS) {
            __builtin_arm_yield();
            continue;
        }
        atomic_fetch_add(&pool->barrier_sleeping, 1);
        if (atomic_load(&pool->barrier_phase) == phase)
            os_sync_wait_on_address(&pool->barrier_phase, phase, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
        atomic_fetch_sub(&pool->barrier_sleeping, 1);
    }
}

void lf_barrier_release(lf_pool *pool) {
    os_sync_wake_by_address_all(&pool->barrier_phase, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

void lf_pool_run(lf_pool *pool) {
    wake(pool, atomic_load(&pool->generation) & 1 ? 1 : 2);
    pool->job(pool->ctx, 0);
}

void lf_pool_prepare(lf_pool *pool) {
    if (!(atomic_load(&pool->generation) & 1)) wake(pool, 1);
}

int lf_performance_cores(void) {
    int cores = 0;
    size_t size = sizeof cores;
    if (sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, NULL, 0) != 0 || cores < 1) return 4;
    return cores > 16 ? 16 : cores;
}
