#include "gguf.h"

#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *p, *end; bool ok; } reader;

static void need(reader *r, uint64_t n) {
    if (!r->ok || n > (uint64_t)(r->end - r->p)) r->ok = false;
}

static uint32_t read_u32(reader *r) {
    need(r, 4);
    if (!r->ok) return 0;
    uint32_t v;
    memcpy(&v, r->p, 4);
    r->p += 4;
    return v;
}

static uint64_t read_u64(reader *r) {
    need(r, 8);
    if (!r->ok) return 0;
    uint64_t v;
    memcpy(&v, r->p, 8);
    r->p += 8;
    return v;
}

static void skip(reader *r, uint64_t n) {
    need(r, n);
    if (r->ok) r->p += n;
}

static size_t scalar_size(uint32_t type) {
    switch (type) {
    case 0: case 1: case 7: return 1;   // u8, i8, bool
    case 2: case 3: return 2;           // u16, i16
    case 4: case 5: case 6: return 4;   // u32, i32, f32
    case 10: case 11: case 12: return 8;   // u64, i64, f64
    default: return 0;
    }
}

static void skip_value(reader *r, uint32_t type, int depth) {
    if (type == GGUF_TYPE_STRING) {
        skip(r, read_u64(r));
    } else if (type == GGUF_TYPE_ARRAY) {
        const uint32_t item = read_u32(r);
        const uint64_t count = read_u64(r);
        if (item == GGUF_TYPE_STRING || item == GGUF_TYPE_ARRAY) {
            if (depth > 2) r->ok = false;
            for (uint64_t i = 0; i < count && r->ok; i++) skip_value(r, item, depth + 1);
        } else {
            const size_t s = scalar_size(item);
            if (!s || count > UINT64_MAX / s) r->ok = false;
            else skip(r, count * s);
        }
    } else {
        const size_t s = scalar_size(type);
        if (!s) r->ok = false;
        else skip(r, s);
    }
}

bool gguf_open(gguf *g, const uint8_t *base, size_t size) {
    memset(g, 0, sizeof *g);
    g->base = base;
    g->size = size;
    reader r = { base, base + size, true };
    if (read_u32(&r) != 0x46554747 || read_u32(&r) != 3) return false;   // "GGUF", version 3
    g->n_tensors = read_u64(&r);
    g->n_kv = read_u64(&r);
    if (!r.ok || g->n_tensors > 100000 || g->n_kv > 100000) return false;
    g->kv = calloc(g->n_kv ? g->n_kv : 1, sizeof(gguf_kv));
    g->tensors = calloc(g->n_tensors ? g->n_tensors : 1, sizeof(gguf_tensor));
    if (!g->kv || !g->tensors) { gguf_close(g); return false; }
    double alignment = 32;
    for (uint64_t i = 0; i < g->n_kv && r.ok; i++) {
        gguf_kv *kv = &g->kv[i];
        kv->key_length = read_u64(&r);
        need(&r, kv->key_length);
        if (!r.ok) break;
        kv->key = (const char *)r.p;
        r.p += kv->key_length;
        kv->type = read_u32(&r);
        kv->value = r.p;
        skip_value(&r, kv->type, 0);
        kv->end = r.p;
    }
    for (uint64_t i = 0; i < g->n_tensors && r.ok; i++) {
        gguf_tensor *t = &g->tensors[i];
        t->name_length = read_u64(&r);
        need(&r, t->name_length);
        if (!r.ok) break;
        t->name = (const char *)r.p;
        r.p += t->name_length;
        t->n_dims = read_u32(&r);
        if (t->n_dims > 4) { r.ok = false; break; }
        for (uint32_t d = 0; d < 4; d++) t->ne[d] = d < t->n_dims ? read_u64(&r) : 1;
        t->type = read_u32(&r);
        t->offset = read_u64(&r);
    }
    if (!r.ok) { gguf_close(g); return false; }
    gguf_number(g, "general.alignment", &alignment);
    const uint64_t align = (uint64_t)alignment;
    if (!align || (align & (align - 1))) { gguf_close(g); return false; }
    const uint64_t offset = ((uint64_t)(r.p - base) + align - 1) & ~(align - 1);
    if (offset > size) { gguf_close(g); return false; }
    g->data = base + offset;
    return true;
}

void gguf_close(gguf *g) {
    free(g->kv);
    free(g->tensors);
    g->kv = NULL;
    g->tensors = NULL;
}

const gguf_kv *gguf_find_kv(const gguf *g, const char *key) {
    const size_t length = strlen(key);
    for (uint64_t i = 0; i < g->n_kv; i++)
        if (g->kv[i].key_length == length && !memcmp(g->kv[i].key, key, length)) return &g->kv[i];
    return NULL;
}

bool gguf_number(const gguf *g, const char *key, double *out) {
    const gguf_kv *kv = gguf_find_kv(g, key);
    if (!kv) return false;
    const uint8_t *p = kv->value;
    switch (kv->type) {
    case 0: *out = *p; return true;
    case 1: *out = (int8_t)*p; return true;
    case 2: { uint16_t v; memcpy(&v, p, 2); *out = v; return true; }
    case 3: { int16_t v; memcpy(&v, p, 2); *out = v; return true; }
    case 4: { uint32_t v; memcpy(&v, p, 4); *out = v; return true; }
    case 5: { int32_t v; memcpy(&v, p, 4); *out = v; return true; }
    case 6: { float v; memcpy(&v, p, 4); *out = v; return true; }
    case 10: { uint64_t v; memcpy(&v, p, 8); *out = (double)v; return true; }
    case 11: { int64_t v; memcpy(&v, p, 8); *out = (double)v; return true; }
    case 12: { double v; memcpy(&v, p, 8); *out = v; return true; }
    default: return false;
    }
}

bool gguf_array(const gguf *g, const char *key, uint32_t *type, uint64_t *count, const uint8_t **items) {
    const gguf_kv *kv = gguf_find_kv(g, key);
    if (!kv || kv->type != GGUF_TYPE_ARRAY || kv->end - kv->value < 12) return false;
    memcpy(type, kv->value, 4);
    memcpy(count, kv->value + 4, 8);
    *items = kv->value + 12;
    return true;
}

const void *gguf_tensor_data(const gguf *g, const char *name, uint32_t type, uint64_t ne0, uint64_t ne1) {
    const size_t length = strlen(name);
    for (uint64_t i = 0; i < g->n_tensors; i++) {
        const gguf_tensor *t = &g->tensors[i];
        if (t->name_length != length || memcmp(t->name, name, length)) continue;
        if (t->type != type || t->ne[0] != ne0 || t->ne[1] != ne1 || t->ne[2] != 1 || t->ne[3] != 1) return NULL;
        const uint64_t element = type == TENSOR_F32 ? 4 : type == TENSOR_F16 ? 2 : type == TENSOR_I8 ? 1 : 0;
        if (!element || ne0 > UINT64_MAX / ne1 / element) return NULL;
        const uint64_t bytes = ne0 * ne1 * element;
        const uint64_t available = (uint64_t)(g->base + g->size - g->data);
        if (t->offset > available || bytes > available - t->offset) return NULL;
        return g->data + t->offset;
    }
    return NULL;
}
