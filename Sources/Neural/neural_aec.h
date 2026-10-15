// Neural echo removal: DTLN-aec below 7.5 kHz, a DTLN-steered, reference-aware gate above it.
// Mono float audio at 48 kHz, processed in fixed hops of naec_hop() samples.
#ifndef NEURAL_AEC_H
#define NEURAL_AEC_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NeuralAec NeuralAec;

typedef struct {
    int high_band;          // 0: DTLN only (no content above 8 kHz), 1: steered, 2: steered + reference-aware
    float steer_power;      // >1 closes the high band harder when DTLN suppresses (2 tested best)
    float acoustic_delay_ms;// speaker -> mic delay, for lining up the reference in the high band (~80)
} NaecOptions;

// model_prefix: path without the "_1.onnx"/"_2.onnx" suffix. Returns NULL and fills `error` on failure.
NeuralAec *naec_create(const char *model_prefix, NaecOptions options, char *error, int error_len);
void naec_destroy(NeuralAec *aec);

int naec_hop(void);                       // samples per naec_process call (8 ms at 48 kHz)
int naec_latency(const NeuralAec *aec);   // output delay in samples, excluding the hop buffering

// One hop of mic + system audio in, one hop of cleaned mic out.
void naec_process(NeuralAec *aec, const float *mic, const float *ref, float *out);

// Learned state (DTLN memory, speaker coupling) so the next session starts settled.
int naec_save_state(const NeuralAec *aec, const char *path);
int naec_load_state(NeuralAec *aec, const char *path);

#ifdef __cplusplus
}
#endif

#endif
