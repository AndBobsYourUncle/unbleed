// Runs the real-time neural pipeline over raw float32 mono 48 kHz files, latency-compensated:
//   naec_offline model_prefix mic.f32 ref.f32 out.f32 [high_band=2] [steer_power=2] [delay_ms=80]
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "../Sources/Neural/neural_aec.h"

static std::vector<float> load(const char *path) {
    std::vector<float> v;
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    float buf[4096];
    size_t n;
    while ((n = fread(buf, sizeof(float), 4096, f)) > 0) v.insert(v.end(), buf, buf + n);
    fclose(f);
    return v;
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: naec_offline model_prefix mic.f32 ref.f32 out.f32 [band] [power] [delay]\n"); return 1; }
    NaecOptions o{argc > 5 ? atoi(argv[5]) : 2, argc > 6 ? (float)atof(argv[6]) : 2.f, argc > 7 ? (float)atof(argv[7]) : 80.f};
    char err[512];
    NeuralAec *aec = naec_create(argv[1], o, err, sizeof err);
    if (!aec) { fprintf(stderr, "create failed: %s\n", err); return 1; }
    auto mic = load(argv[2]), ref = load(argv[3]);
    int hop = naec_hop(), lat = naec_latency(aec);
    size_t hops = std::min(mic.size(), ref.size()) / hop;
    std::vector<float> out(hops * hop);
    // NAEC_TRACE=1 prints the speaker→mic delay estimate once per second (to study its stability)
    bool trace = getenv("NAEC_TRACE") != nullptr;
    for (size_t k = 0; k < hops; k++) {
        naec_process(aec, &mic[k * hop], &ref[k * hop], &out[k * hop]);
        if (trace && (k * hop) % 48000 < size_t(hop)) fprintf(stderr, "%zu %.1f\n", k * hop / 48000, naec_acoustic_delay_ms(aec));
    }
    fprintf(stderr, "speaker→mic delay: %.1f ms\n", naec_acoustic_delay_ms(aec));
    naec_destroy(aec);
    FILE *f = fopen(argv[4], "wb");
    fwrite(out.data() + lat, sizeof(float), out.size() - lat, f);
    fclose(f);
}
