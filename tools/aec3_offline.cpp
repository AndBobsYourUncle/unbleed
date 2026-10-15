// Runs the AEC3 bridge over raw float32 mono 48 kHz files: aec3_offline mic.f32 ref.f32 out.f32 transparency
#include <cstdio>
#include <cstdlib>
#include <vector>
#include "../Sources/AEC/aec_bridge.h"

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
    if (argc != 5) { fprintf(stderr, "usage: aec3_offline mic.f32 ref.f32 out.f32 transparency\n"); return 1; }
    auto mic = load(argv[1]), ref = load(argv[2]);
    size_t frames = std::min(mic.size(), ref.size()) / 480;
    AecHandle *aec = aec_create(AecOptions{48000, (float)atof(argv[4]), -1, 1, 80});
    std::vector<float> out(frames * 480);
    for (size_t k = 0; k < frames; k++) {
        float work[480];
        std::copy(&mic[k * 480], &mic[k * 480] + 480, work);
        aec_process_render(aec, &ref[k * 480]);
        aec_process_capture(aec, work);
        std::copy(work, work + 480, &out[k * 480]);
    }
    aec_destroy(aec);
    FILE *f = fopen(argv[3], "wb");
    fwrite(out.data(), sizeof(float), out.size(), f);
    fclose(f);
}
