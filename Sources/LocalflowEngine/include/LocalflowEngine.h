// The cleanup model's engine: a Qwen3 forward pass on the CPU (NEON, plus SME on M4 and later)
// over a model file written by lf_convert. One sequence, greedy decoding: lf_decode returns the
// most likely next token for each requested position. Also the speech models' decoders.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lf_model lf_model;

/// Converts a Qwen3 GGUF with F16 weights into the engine's file (int8 weights with one scale per
/// row, Hadamard-rotated; see convert.c). Returns NULL on success, else a static description.
const char *lf_convert(const char *source_path, const char *output_path);

/// Maps a converted model file and starts the engine's threads. NULL if the file is missing,
/// unreadable or of another format version.
lf_model *lf_load(const char *path, int n_ctx, int n_batch);
void lf_free(lf_model *model);

/// Evaluates tokens[0..n) at positions pos..pos+n-1, replacing anything cached from `pos` on, and
/// writes the most likely next token after each of the last `n_out` of them to argmax[0..n_out).
/// Returns 0, or -1 for arguments out of range.
int lf_decode(lf_model *model, const int32_t *tokens, int n, int pos, int n_out, int32_t *argmax);

/// The vocabulary, for the tokenizer: token texts (GPT-2 byte-level), token types and BPE merges
/// as stored in the GGUF, and whether a token ends generation.
int lf_vocab_size(const lf_model *model);
const char *lf_token_text(const lf_model *model, int token, size_t *length);
int32_t lf_token_type(const lf_model *model, int token);
int lf_merge_count(const lf_model *model);
const char *lf_merge(const lf_model *model, int index, size_t *length);
bool lf_is_end(const lf_model *model, int32_t token);

typedef struct lf_rnnt lf_rnnt;

/// Parakeet Unified 0.6B's RNNT decoder, from the weights/weight.bin of its CoreML bundles
/// parakeet_unified_decoder and parakeet_unified_joint_decision_single_step, and its threads.
/// NULL if a file is missing or not laid out as expected.
lf_rnnt *lf_rnnt_load(const char *decoder_weights, const char *joint_weights);
void lf_rnnt_free(lf_rnnt *decoder);

/// Wakes the decoder's threads to wait for a decode. Call as the encoder starts: on cores that
/// have been idle they take ~6 ms to wake, and spinning brings the cores up to speed.
void lf_rnnt_prepare(lf_rnnt *decoder);

/// Greedy decoding of `frames` encoder frames from a fresh state, as FluidAudio's
/// UnifiedRnntDecoder (at most 10 tokens per frame); feature d of frame t is encoded[d * stride + t].
/// Writes up to `max` tokens and the frames they were emitted at; returns how many, or -1.
int lf_rnnt_decode(lf_rnnt *decoder, const float *encoded, long stride, int frames, int32_t *tokens,
                   int32_t *token_frames, int max);

/// Parakeet TDT 0.6B v3's decoder, from the weights/weight.bin of its CoreML bundles Decoder and
/// JointDecisionv3. NULL if a file is missing or not laid out as expected. Freed and prepared as
/// lf_rnnt_free and lf_rnnt_prepare.
lf_rnnt *lf_tdt_load(const char *decoder_weights, const char *joint_weights);

/// Greedy decoding from a fresh state as FluidAudio's TdtDecoderV3 with its default TdtConfig, of the
/// encoder's `frames` valid frames (feature d of frame t is encoded[d * stride + t]), of which the
/// first `valid` hold audio; `last` adds the last window's end-of-audio flush. Writes up to `max`
/// tokens (at most 160 are emitted) with the frame each was emitted at, its duration in frames and
/// its probability; returns how many, or -1.
int lf_tdt_decode(lf_rnnt *decoder, const float *encoded, long stride, int frames, int valid, bool last,
                  int32_t *tokens, int32_t *token_frames, int32_t *durations, float *probabilities, int max);

#ifdef __cplusplus
}
#endif
