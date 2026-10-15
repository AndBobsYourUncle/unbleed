// C interface to WebRTC's AEC3 echo canceller, callable from Swift.
// All audio is mono float in [-1, 1], delivered in 10 ms frames (sample_rate / 100 samples).
#ifndef AEC_BRIDGE_H
#define AEC_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AecHandle AecHandle;

typedef struct {
    int sample_rate;          // 48000 recommended
    float transparency;       // 1 = stock AEC3 suppression; higher lets more near-end through; >= 1000 ~ subtraction only
    int noise_suppression;    // -1 off, 0 low, 1 moderate, 2 high, 3 very high
    int high_pass_filter;     // 0/1
    int initial_delay_ms;     // hint for render->capture delay
} AecOptions;

typedef struct {
    double erle_db;           // echo return loss enhancement; NaN if unavailable
    int delay_ms;             // estimated delay; -1 if unavailable
} AecStats;

AecHandle *aec_create(AecOptions options);
void aec_destroy(AecHandle *aec);

// Feed 10 ms of what the speakers are playing (system audio).
int aec_process_render(AecHandle *aec, const float *render);
// Process 10 ms of microphone audio in place.
int aec_process_capture(AecHandle *aec, float *capture);

AecStats aec_stats(AecHandle *aec);

#ifdef __cplusplus
}
#endif

#endif
