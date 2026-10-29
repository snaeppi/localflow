// Minimal GGUF v3 reading, for the engine (its own model file) and the converter (the F16 download).
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { GGUF_TYPE_STRING = 8, GGUF_TYPE_ARRAY = 9 };
enum { TENSOR_F32 = 0, TENSOR_F16 = 1, TENSOR_I8 = 24 };

/// A metadata entry; `value` points at its raw value (after the type), `end` just past it.
typedef struct {
    const char *key;
    size_t key_length;
    uint32_t type;
    const uint8_t *value, *end;
} gguf_kv;

typedef struct {
    const char *name;
    size_t name_length;
    uint32_t n_dims;
    uint64_t ne[4];
    uint32_t type;
    uint64_t offset;
} gguf_tensor;

typedef struct {
    const uint8_t *base;
    size_t size;
    gguf_kv *kv;
    uint64_t n_kv;
    gguf_tensor *tensors;
    uint64_t n_tensors;
    const uint8_t *data;
} gguf;

/// Parses the header of a mapped file; false if it isn't well-formed GGUF v3. Free with gguf_close.
bool gguf_open(gguf *g, const uint8_t *base, size_t size);
void gguf_close(gguf *g);
const gguf_kv *gguf_find_kv(const gguf *g, const char *key);
/// Any scalar numeric value, as a double.
bool gguf_number(const gguf *g, const char *key, double *out);
/// An array's element type, count and first item.
bool gguf_array(const gguf *g, const char *key, uint32_t *type, uint64_t *count, const uint8_t **items);
/// The data of a 1- or 2-dimensional tensor of this type and shape, or NULL.
const void *gguf_tensor_data(const gguf *g, const char *name, uint32_t type, uint64_t ne0, uint64_t ne1);
