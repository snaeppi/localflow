// Converts the cleanup model's F16 download into the engine's file, once, at install.
//
// Weights become int8 with one scale per row, and activations are quantized the same way at run
// time (one scale per token), which lets the matrix multiplications run as pure integer dot
// products: ~84% of the NEON peak instead of ~64% with Q8_0's per-32 scales, and on SME (M4 and
// later) without leaving the integer tiles. One scale per token alone would cost accuracy
// (activation outliers), so the model is rotated first, as in QuaRot: the residual stream by a
// Hadamard matrix (the RMS norm weights folded into the next matrices, so the norm commutes with
// it), each value/output head by H_128, and the FFN hidden state by blocks of H_1024 (the one
// rotation done at run time). Agreement with F16 then equals Q8_0's (bench/README.md).
#include "LocalflowEngine.h"
#include "gguf.h"
#include "internal.h"

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

// MARK: Writing

typedef struct { FILE *file; bool ok; uint64_t written; } writer;

static void put(writer *w, const void *p, size_t n) {
    if (w->ok && n && fwrite(p, 1, n, w->file) != n) w->ok = false;
    w->written += n;
}

static void put_u32(writer *w, uint32_t v) { put(w, &v, 4); }
static void put_u64(writer *w, uint64_t v) { put(w, &v, 8); }

static void put_string(writer *w, const char *s, size_t n) {
    put_u64(w, n);
    put(w, s, n);
}

static void put_key(writer *w, const char *key, uint32_t type) {
    put_string(w, key, strlen(key));
    put_u32(w, type);
}

static void pad(writer *w) {
    static const uint8_t zeros[LF_ALIGN];
    put(w, zeros, (LF_ALIGN - w->written % LF_ALIGN) % LF_ALIGN);
}

// MARK: Plan

typedef struct {
    char name[64];
    uint32_t type;
    uint64_t ne0, ne1, offset;
} planned;

static uint64_t tensor_bytes(const planned *t) {
    return t->ne0 * t->ne1 * (t->type == TENSOR_F32 ? 4 : t->type == TENSOR_F16 ? 2 : 1);
}

typedef struct {
    planned *items;
    int count;
} plan;

static void add(plan *p, uint32_t type, uint64_t ne0, uint64_t ne1, const char *format, int layer) {
    planned *t = &p->items[p->count++];
    snprintf(t->name, sizeof t->name, format, layer);
    t->type = type;
    t->ne0 = ne0;
    t->ne1 = ne1;
}

// MARK: Matrices

typedef struct {
    const __fp16 *src;
    const float *gamma;   // input-column scales folded in (the preceding RMS norm's weights)
    float *w;
    int8_t *q;
    float *s;
    int K, N, col_block, row_block;
} matrix_job;

static void load_rows(void *context, size_t r) {
    const matrix_job *j = context;
    float *w = j->w + r * j->K;
    for (int k = 0; k < j->K; k++) w[k] = (float)j->src[r * j->K + k] * (j->gamma ? j->gamma[k] : 1.0f);
    if (j->col_block) for (int b = 0; b < j->K; b += j->col_block) lf_fwht(w + b, j->col_block);
}

static void rotate_column(void *context, size_t c) {
    const matrix_job *j = context;
    float t[8192];
    for (int b = 0; b < j->N; b += j->row_block) {
        for (int i = 0; i < j->row_block; i++) t[i] = j->w[(size_t)(b + i) * j->K + c];
        lf_fwht(t, j->row_block);
        for (int i = 0; i < j->row_block; i++) j->w[(size_t)(b + i) * j->K + c] = t[i];
    }
}

/// Rows as int8 with one scale each, in the kernels' layout: [N/16][K/4][16 rows][4 columns].
static void quantize_group(void *context, size_t group) {
    const matrix_job *j = context;
    const int K = j->K;
    for (int i = 0; i < 16; i++) {
        const size_t r = group * 16 + i;
        const float *w = j->w + r * K;
        float amax = 0;
        for (int k = 0; k < K; k++) amax = fmaxf(amax, fabsf(w[k]));
        const float d = amax / 127.0f, id = d ? 1.0f / d : 0.0f;
        j->s[r] = d;
        int8_t *q = j->q + group * 16 * K;
        for (int k = 0; k < K; k++) q[(size_t)(k / 4) * 64 + i * 4 + k % 4] = (int8_t)lrintf(w[k] * id);
    }
}

/// Converts and writes one matrix (and its scales). col_block / row_block: Hadamard blocks applied
/// along the input / output dimension (0: none).
static void write_matrix(writer *w, const __fp16 *src, const float *gamma, int K, int N, int col_block, int row_block,
                         float *buffer, int8_t *q, float *s) {
    // Rows are independent unless rotated along the output dimension, so big matrices go in chunks.
    const int chunk = row_block ? N : 8192;
    for (int r0 = 0; r0 < N; r0 += chunk) {
        const int rows = N - r0 < chunk ? N - r0 : chunk;
        matrix_job job = { src + (size_t)r0 * K, gamma, buffer, q, s + r0, K, rows, col_block, row_block };
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        dispatch_apply_f(rows, queue, &job, load_rows);
        if (row_block) dispatch_apply_f(K, queue, &job, rotate_column);
        dispatch_apply_f(rows / 16, queue, &job, quantize_group);
        put(w, q, (size_t)rows * K);
    }
    pad(w);
    put(w, s, (size_t)N * sizeof(float));
    pad(w);
}

// MARK: Convert

/// Tokens llama.cpp ends generation on (its special_eog_ids rule, for the names Qwen3 uses).
static bool ends_generation(const uint8_t *text, uint64_t length, int64_t id, double eos) {
    static const char *names[] = { "<|endoftext|>", "<|im_end|>", "<|fim_pad|>", "<|repo_name|>", "<|file_sep|>",
                                   "</s>", "<|eot_id|>", "<|eom_id|>", "<|end|>", "<end_of_turn>" };
    if (id == (int64_t)eos) return true;
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (strlen(names[i]) == length && !memcmp(names[i], text, length)) return true;
    return false;
}

const char *lf_convert(const char *source_path, const char *output_path) {
    int fd = open(source_path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        return "cannot read the downloaded model";
    }
    const size_t size = (size_t)st.st_size;
    const uint8_t *base = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (base == MAP_FAILED) return "cannot map the downloaded model";
    const char *error = NULL;
    gguf g;
    FILE *file = NULL;
    float *buffer = NULL, *scales = NULL;
    int8_t *q = NULL;
    int32_t *eog = NULL;
    plan p = { 0 };
    if (!gguf_open(&g, base, size)) { error = "the downloaded model isn't GGUF v3"; goto done; }

    double layers, embd, ff, heads, heads_kv, key_length, rope, eps, eos = -1;
    const gguf_kv *arch = gguf_find_kv(&g, "general.architecture");
    const bool qwen3 = arch && arch->type == GGUF_TYPE_STRING && arch->end - arch->value == 13 &&
                       !memcmp(arch->value + 8, "qwen3", 5);
    if (!qwen3 || !gguf_number(&g, "qwen3.block_count", &layers) || !gguf_number(&g, "qwen3.embedding_length", &embd) ||
        !gguf_number(&g, "qwen3.feed_forward_length", &ff) || !gguf_number(&g, "qwen3.attention.head_count", &heads) ||
        !gguf_number(&g, "qwen3.attention.head_count_kv", &heads_kv) ||
        !gguf_number(&g, "qwen3.attention.key_length", &key_length) ||
        !gguf_number(&g, "qwen3.rope.freq_base", &rope) ||
        !gguf_number(&g, "qwen3.attention.layer_norm_rms_epsilon", &eps)) {
        error = "the downloaded model isn't Qwen3";
        goto done;
    }
    gguf_number(&g, "tokenizer.ggml.eos_token_id", &eos);
    const int L = (int)layers, E = (int)embd, F = (int)ff, H = (int)heads, HK = (int)heads_kv;
    const int Q = H * HD, KV = HK * HD, block = lf_ffn_block(F, E);
    uint32_t tokens_type, types_type, merges_type;
    uint64_t V, n_types, n_merges;
    const uint8_t *tokens, *types, *merges;
    if (key_length != HD || L < 1 || E < 256 || E > 8192 || (E & (E - 1)) || H < 1 || HK < 1 || H != 2 * HK ||
        F % 16 || F % block || block < 128 ||
        !gguf_array(&g, "tokenizer.ggml.tokens", &tokens_type, &V, &tokens) || tokens_type != GGUF_TYPE_STRING ||
        !gguf_array(&g, "tokenizer.ggml.token_type", &types_type, &n_types, &types) || types_type != 5 ||
        n_types != V || V % 16 || !gguf_array(&g, "tokenizer.ggml.merges", &merges_type, &n_merges, &merges) ||
        merges_type != GGUF_TYPE_STRING) {
        error = "the downloaded model has an unsupported shape";
        goto done;
    }

    // End-of-generation tokens.
    eog = malloc(64 * sizeof(int32_t));
    int n_eog = 0;
    const uint8_t *t = tokens;
    for (uint64_t i = 0; i < V && eog; i++) {
        uint64_t length;
        memcpy(&length, t, 8);
        if (ends_generation(t + 8, length, (int64_t)i, eos) && n_eog < 64) eog[n_eog++] = (int32_t)i;
        t += 8 + length;
    }

    // Every tensor, in file order.
    p.items = calloc((size_t)L * 16 + 8, sizeof(planned));
    if (!eog || !p.items) { error = "out of memory"; goto done; }
    add(&p, TENSOR_F16, E, V, "token_embd.weight", 0);
    add(&p, TENSOR_I8, E, V, "output.weight", 0);
    add(&p, TENSOR_F32, V, 1, "output.scale", 0);
    for (int il = 0; il < L; il++) {
        static const struct { const char *name; int in, out; } m[] = {
            { "attn_q", 0, 1 }, { "attn_k", 0, 2 }, { "attn_v", 0, 2 }, { "attn_output", 1, 0 },
            { "ffn_gate", 0, 3 }, { "ffn_up", 0, 3 }, { "ffn_down", 3, 0 },
        };
        const int dims[4] = { E, Q, KV, F };
        for (int i = 0; i < 7; i++) {
            char name[64];
            snprintf(name, sizeof name, "blk.%%d.%s.weight", m[i].name);
            add(&p, TENSOR_I8, dims[m[i].in], dims[m[i].out], name, il);
            snprintf(name, sizeof name, "blk.%%d.%s.scale", m[i].name);
            add(&p, TENSOR_F32, dims[m[i].out], 1, name, il);
        }
        add(&p, TENSOR_F32, HD, 1, "blk.%d.attn_q_norm.weight", il);
        add(&p, TENSOR_F32, HD, 1, "blk.%d.attn_k_norm.weight", il);
    }
    uint64_t offset = 0;
    for (int i = 0; i < p.count; i++) {
        p.items[i].offset = offset;
        offset += (tensor_bytes(&p.items[i]) + LF_ALIGN - 1) / LF_ALIGN * LF_ALIGN;
    }

    file = fopen(output_path, "wb");
    if (!file) { error = "cannot write the converted model"; goto done; }
    writer w = { file, true, 0 };
    put_u32(&w, 0x46554747);
    put_u32(&w, 3);
    put_u64(&w, (uint64_t)p.count);
    put_u64(&w, 16);   // metadata entries below
    put_key(&w, "general.architecture", GGUF_TYPE_STRING);
    put_string(&w, "qwen3", 5);
    put_key(&w, "general.alignment", 4);
    put_u32(&w, LF_ALIGN);
    put_key(&w, "localflow.format", 4);
    put_u32(&w, LF_FORMAT);
    put_key(&w, "localflow.ffn_rotation_block", 4);
    put_u32(&w, (uint32_t)block);
    const char *copied[] = { "qwen3.block_count", "qwen3.embedding_length", "qwen3.feed_forward_length",
                             "qwen3.attention.head_count", "qwen3.attention.head_count_kv",
                             "qwen3.attention.key_length", "qwen3.rope.freq_base",
                             "qwen3.attention.layer_norm_rms_epsilon", "tokenizer.ggml.tokens",
                             "tokenizer.ggml.token_type", "tokenizer.ggml.merges" };
    for (size_t i = 0; i < sizeof copied / sizeof *copied; i++) {
        const gguf_kv *kv = gguf_find_kv(&g, copied[i]);
        put_string(&w, kv->key, kv->key_length);
        put_u32(&w, kv->type);
        put(&w, kv->value, (size_t)(kv->end - kv->value));
    }
    put_key(&w, "localflow.end_tokens", GGUF_TYPE_ARRAY);
    put_u32(&w, 5);
    put_u64(&w, (uint64_t)n_eog);
    put(&w, eog, (size_t)n_eog * sizeof(int32_t));
    for (int i = 0; i < p.count; i++) {
        const planned *pt = &p.items[i];
        put_string(&w, pt->name, strlen(pt->name));
        put_u32(&w, pt->ne1 > 1 ? 2 : 1);
        put_u64(&w, pt->ne0);
        if (pt->ne1 > 1) put_u64(&w, pt->ne1);
        put_u32(&w, pt->type);
        put_u64(&w, pt->offset);
    }
    pad(&w);

    // The largest piece converted at once: 8,192 rows of the output layer, or a whole matrix.
    const size_t rows_max = (size_t)(F > Q ? (F > 8192 ? F : 8192) : (Q > 8192 ? Q : 8192));
    buffer = malloc(rows_max * E * sizeof(float));
    q = malloc(rows_max * E);
    scales = malloc((size_t)V * sizeof(float));
    if (!buffer || !q || !scales) { error = "out of memory"; goto done; }

    // The embedding, rotated like the residual stream it starts.
    const __fp16 *embedding = gguf_tensor_data(&g, "token_embd.weight", TENSOR_F16, E, V);
    const __fp16 *output = gguf_tensor_data(&g, "output.weight", TENSOR_F16, E, V);
    const float *output_norm = gguf_tensor_data(&g, "output_norm.weight", TENSOR_F32, E, 1);
    if (!embedding || !output || !output_norm) { error = "the downloaded model is missing tensors"; goto done; }
    __fp16 *rotated = (__fp16 *)q;
    for (uint64_t r0 = 0; r0 < V; r0 += 4096) {
        const size_t rows = V - r0 < 4096 ? (size_t)(V - r0) : 4096;
        matrix_job job = { embedding + r0 * E, NULL, buffer, NULL, NULL, E, (int)rows, E, 0 };
        dispatch_apply_f(rows, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), &job, load_rows);
        for (size_t i = 0; i < rows * E; i++) rotated[i] = (__fp16)buffer[i];
        put(&w, rotated, rows * E * sizeof(__fp16));
    }
    pad(&w);
    write_matrix(&w, output, output_norm, E, (int)V, E, 0, buffer, q, scales);

    for (int il = 0; il < L && w.ok && !error; il++) {
        char name[64];
        const __fp16 *mat[7];
        const char *names[7] = { "attn_q", "attn_k", "attn_v", "attn_output", "ffn_gate", "ffn_up", "ffn_down" };
        const int ks[7] = { E, E, E, Q, E, E, F }, ns[7] = { Q, KV, KV, E, F, F, E };
        for (int i = 0; i < 7; i++) {
            snprintf(name, sizeof name, "blk.%d.%s.weight", il, names[i]);
            mat[i] = gguf_tensor_data(&g, name, TENSOR_F16, ks[i], ns[i]);
        }
        const float *norms[4];
        const char *norm_names[4] = { "attn_norm", "ffn_norm", "attn_q_norm", "attn_k_norm" };
        const int norm_size[4] = { E, E, HD, HD };
        for (int i = 0; i < 4; i++) {
            snprintf(name, sizeof name, "blk.%d.%s.weight", il, norm_names[i]);
            norms[i] = gguf_tensor_data(&g, name, TENSOR_F32, norm_size[i], 1);
        }
        bool found = norms[0] && norms[1] && norms[2] && norms[3];
        for (int i = 0; i < 7; i++) found = found && mat[i];
        if (!found) { error = "the downloaded model is missing tensors"; break; }
        write_matrix(&w, mat[0], norms[0], E, Q, E, 0, buffer, q, scales);
        write_matrix(&w, mat[1], norms[0], E, KV, E, 0, buffer, q, scales);
        write_matrix(&w, mat[2], norms[0], E, KV, E, HD, buffer, q, scales);
        write_matrix(&w, mat[3], NULL, Q, E, HD, E, buffer, q, scales);
        write_matrix(&w, mat[4], norms[1], E, F, E, 0, buffer, q, scales);
        write_matrix(&w, mat[5], norms[1], E, F, E, 0, buffer, q, scales);
        write_matrix(&w, mat[6], NULL, F, E, block, E, buffer, q, scales);
        put(&w, norms[2], HD * sizeof(float));
        pad(&w);
        put(&w, norms[3], HD * sizeof(float));
        pad(&w);
    }
    if (!error && (!w.ok || fflush(file) != 0 || fsync(fileno(file)) != 0)) error = "cannot write the converted model";

done:
    if (file && fclose(file) != 0 && !error) error = "cannot write the converted model";
    if (error && file) unlink(output_path);
    free(buffer);
    free(q);
    free(scales);
    free(eog);
    free(p.items);
    gguf_close(&g);
    munmap((void *)base, size);
    return error;
}
