#include "neural_aec.h"

#include <Accelerate/Accelerate.h>
#include <onnxruntime_cxx_api.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr int kRate = 48000;
constexpr int kHop = 384;            // 8 ms at 48 kHz = one DTLN shift (128 at 16 kHz)
constexpr int kBlock16 = 512;        // DTLN window at 16 kHz
constexpr int kShift16 = 128;
constexpr int kBins16 = kBlock16 / 2 + 1;
constexpr int kStateSize = 1 * 2 * 512 * 2;
constexpr int kCrossTaps = 255;      // crossover / band filters (delay 127)
constexpr int kResampleTaps = 61;    // same design as scipy resample_poly(.., 1, 3) (delay 30)
constexpr int kStftSize = 512;       // high-band gate STFT at 48 kHz
constexpr int kStftHop = 128;
constexpr int kStftBins = kStftSize / 2 + 1;

// ---------- small DSP helpers ----------

double bessel_i0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 50; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

// Windowed-sinc low-pass, like scipy.signal.firwin (Hamming) or resample_poly (Kaiser beta=5).
std::vector<float> lowpass(int taps, double cutoff_hz, bool kaiser) {
    std::vector<float> h(taps);
    double fc = cutoff_hz / kRate, mid = (taps - 1) / 2.0, sum = 0;
    for (int i = 0; i < taps; i++) {
        double x = i - mid;
        double sinc = x == 0 ? 2 * fc : std::sin(2 * M_PI * fc * x) / (M_PI * x);
        double w = kaiser ? bessel_i0(5.0 * std::sqrt(1 - std::pow(x / mid, 2))) / bessel_i0(5.0)
                          : 0.54 - 0.46 * std::cos(2 * M_PI * i / (taps - 1));
        h[i] = float(sinc * w);
        sum += h[i];
    }
    for (auto &v : h) v = float(v / sum);  // unity gain at DC
    return h;
}

class Fir {
public:
    explicit Fir(std::vector<float> taps) : h_(std::move(taps)), buf_(2 * h_.size(), 0.f) {
        std::reverse(h_.begin(), h_.end());
    }
    float process(float x) {
        size_t n = h_.size();
        buf_[pos_] = buf_[pos_ + n] = x;
        pos_ = (pos_ + 1) % n;
        float y;
        vDSP_dotpr(&buf_[pos_], 1, h_.data(), 1, &y, n);
        return y;
    }
private:
    std::vector<float> h_, buf_;
    size_t pos_ = 0;
};

class DelayLine {
public:
    explicit DelayLine(int samples) : buf_(std::max(samples, 0) + 1, 0.f) {}
    float process(float x) {
        buf_[pos_] = x;
        pos_ = (pos_ + 1) % buf_.size();
        return buf_[pos_];
    }
private:
    std::vector<float> buf_;
    size_t pos_ = 0;
};

// Real FFT with numpy's scaling (forward unnormalized, inverse divides by n).
class RealFft {
public:
    explicit RealFft(int n) : n_(n), log2n_(int(std::log2(n))), re_(n / 2), im_(n / 2) {
        setup_ = vDSP_create_fftsetup(log2n_, kFFTRadix2);
    }
    ~RealFft() { vDSP_destroy_fftsetup(setup_); }

    // x[n] -> re/im[n/2+1]
    void forward(const float *x, float *re, float *im) {
        DSPSplitComplex s{re_.data(), im_.data()};
        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(x), 2, &s, 1, n_ / 2);
        vDSP_fft_zrip(setup_, &s, 1, log2n_, kFFTDirection_Forward);
        re[0] = re_[0] * 0.5f; im[0] = 0;
        re[n_ / 2] = im_[0] * 0.5f; im[n_ / 2] = 0;
        for (int k = 1; k < n_ / 2; k++) { re[k] = re_[k] * 0.5f; im[k] = im_[k] * 0.5f; }
    }

    // re/im[n/2+1] -> x[n]
    void inverse(const float *re, const float *im, float *x) {
        re_[0] = re[0]; im_[0] = re[n_ / 2];
        for (int k = 1; k < n_ / 2; k++) { re_[k] = re[k]; im_[k] = im[k]; }
        DSPSplitComplex s{re_.data(), im_.data()};
        vDSP_fft_zrip(setup_, &s, 1, log2n_, kFFTDirection_Inverse);
        vDSP_ztoc(&s, 1, reinterpret_cast<DSPComplex *>(x), 2, n_ / 2);
        float scale = 1.0f / n_;
        vDSP_vsmul(x, 1, &scale, x, 1, n_);
    }

private:
    int n_, log2n_;
    FFTSetup setup_;
    std::vector<float> re_, im_;
};

// ---------- DTLN-aec at 16 kHz ----------

class Dtln {
public:
    Dtln(Ort::Env &env, const std::string &prefix) : fft_(kBlock16) {
        Ort::SessionOptions so;
        so.SetIntraOpNumThreads(1);
        so.SetInterOpNumThreads(1);
        so.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        so.AddConfigEntry("session.intra_op.allow_spinning", "0");
        s1_ = std::make_unique<Ort::Session>(env, (prefix + "_1.onnx").c_str(), so);
        s2_ = std::make_unique<Ort::Session>(env, (prefix + "_2.onnx").c_str(), so);
        names1_ = input_names(*s1_, {"input_3", "input_4", "input_5"});
        names2_ = input_names(*s2_, {"input_6", "input_7", "input_8"});
        reset();
    }

    void reset() {
        std::fill(std::begin(mic_), std::end(mic_), 0.f);
        std::fill(std::begin(ref_), std::end(ref_), 0.f);
        std::fill(std::begin(ola_), std::end(ola_), 0.f);
        std::fill(std::begin(state1_), std::end(state1_), 0.f);
        std::fill(std::begin(state2_), std::end(state2_), 0.f);
    }

    // 128 new samples of mic and reference in, 128 samples out (delayed by 384).
    void process(const float *mic, const float *ref, float *out) {
        std::memmove(mic_, mic_ + kShift16, sizeof(float) * (kBlock16 - kShift16));
        std::memmove(ref_, ref_ + kShift16, sizeof(float) * (kBlock16 - kShift16));
        std::memcpy(mic_ + kBlock16 - kShift16, mic, sizeof(float) * kShift16);
        std::memcpy(ref_ + kBlock16 - kShift16, ref, sizeof(float) * kShift16);

        fft_.forward(mic_, re_, im_);
        vDSP_Length nb = kBins16;
        DSPSplitComplex spec{re_, im_};
        vDSP_zvabs(&spec, 1, mic_mag_, 1, nb);
        float rre[kBins16], rim[kBins16];
        fft_.forward(ref_, rre, rim);
        DSPSplitComplex rspec{rre, rim};
        vDSP_zvabs(&rspec, 1, ref_mag_, 1, nb);

        auto mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const int64_t mag_shape[] = {1, 1, kBins16}, state_shape[] = {1, 2, 512, 2}, blk_shape[] = {1, 1, kBlock16};
        try {
            Ort::Value in1[] = {
                Ort::Value::CreateTensor<float>(mem, mic_mag_, kBins16, mag_shape, 3),
                Ort::Value::CreateTensor<float>(mem, ref_mag_, kBins16, mag_shape, 3),
                Ort::Value::CreateTensor<float>(mem, state1_, kStateSize, state_shape, 4)};
            Ort::Value out1[] = {
                Ort::Value::CreateTensor<float>(mem, mask_, kBins16, mag_shape, 3),
                Ort::Value::CreateTensor<float>(mem, state_out_, kStateSize, state_shape, 4)};
            s1_->Run(Ort::RunOptions{nullptr}, names1_.ptrs.data(), in1, 3, out_names_, out1, 2);
            std::memcpy(state1_, state_out_, sizeof(state1_));

            vDSP_vmul(re_, 1, mask_, 1, re_, 1, nb);
            vDSP_vmul(im_, 1, mask_, 1, im_, 1, nb);
            fft_.inverse(re_, im_, est_);

            Ort::Value in2[] = {
                Ort::Value::CreateTensor<float>(mem, est_, kBlock16, blk_shape, 3),
                Ort::Value::CreateTensor<float>(mem, ref_, kBlock16, blk_shape, 3),
                Ort::Value::CreateTensor<float>(mem, state2_, kStateSize, state_shape, 4)};
            Ort::Value out2[] = {
                Ort::Value::CreateTensor<float>(mem, block_, kBlock16, blk_shape, 3),
                Ort::Value::CreateTensor<float>(mem, state_out_, kStateSize, state_shape, 4)};
            s2_->Run(Ort::RunOptions{nullptr}, names2_.ptrs.data(), in2, 3, out_names_, out2, 2);
            std::memcpy(state2_, state_out_, sizeof(state2_));
        } catch (const Ort::Exception &) {
            std::fill(std::begin(block_), std::end(block_), 0.f);  // never take down the audio thread
        }

        std::memmove(ola_, ola_ + kShift16, sizeof(float) * (kBlock16 - kShift16));
        std::fill(ola_ + kBlock16 - kShift16, ola_ + kBlock16, 0.f);
        vDSP_vadd(ola_, 1, block_, 1, ola_, 1, kBlock16);
        std::memcpy(out, ola_, sizeof(float) * kShift16);
    }

    static constexpr int kLatency16 = kBlock16 - kShift16;

    float state1_[kStateSize], state2_[kStateSize];

private:
    struct Names {
        std::vector<std::string> owned;
        std::vector<const char *> ptrs;
    };

    // Inputs are (spectrum or block, reference, state). Our own fine-tuned exports name them
    // "mic", "ref", "state"; the original DTLN-aec conversion uses the tflite names.
    static Names input_names(Ort::Session &s, std::vector<std::string> fallback) {
        Ort::AllocatorWithDefaultOptions alloc;
        std::vector<std::string> have;
        for (size_t i = 0; i < s.GetInputCount(); i++) have.push_back(s.GetInputNameAllocated(i, alloc).get());
        auto has = [&](const char *n) { return std::find(have.begin(), have.end(), n) != have.end(); };
        Names names;
        names.owned = has("mic") && has("ref") && has("state") ? std::vector<std::string>{"mic", "ref", "state"} : fallback;
        for (auto &n : names.owned) names.ptrs.push_back(n.c_str());
        return names;
    }

    RealFft fft_;
    std::unique_ptr<Ort::Session> s1_, s2_;
    Names names1_, names2_;
    const char *out_names_[2] = {"Identity", "Identity_1"};
    float mic_[kBlock16], ref_[kBlock16], ola_[kBlock16];
    float re_[kBins16], im_[kBins16], mic_mag_[kBins16], ref_mag_[kBins16], mask_[kBins16];
    float est_[kBlock16], block_[kBlock16], state_out_[kStateSize];
};

// ---------- reference-aware high-band gate ----------

// Streaming STFT gate: per bin, estimate how much of the mic is explained by the (delayed) game
// reference times a learned speaker->mic coupling, and turn those bins down. Smoothed in time and
// frequency so it doesn't produce "musical noise" chirps.
class HighBandGate {
public:
    HighBandGate() : fft_(kStftSize) {
        for (int i = 0; i < kStftSize; i++) window_[i] = float(std::sqrt(0.5 - 0.5 * std::cos(2 * M_PI * i / kStftSize)));
        std::fill(std::begin(coupling_), std::end(coupling_), 1e-3f);
        std::fill(std::begin(gain_), std::end(gain_), 1.f);
        // offline tuning used 384-sample frames; rescale per-frame rates to this hop
        double k = double(kStftHop) / 384.0;
        smooth_ = float(std::pow(0.7, k));
        down_ = float(1 - std::pow(0.7, k));
        up_ = float(1 - std::pow(0.995, k));
    }

    static constexpr int kLatency = kStftSize - kStftHop;

    // kStftHop samples of high-band mic and high-band reference in, kStftHop out.
    void process(const float *mic, const float *ref, float *out) {
        shift_in(mic_, mic);
        shift_in(ref_, ref);

        float frame[kStftSize], mre[kStftBins], mim[kStftBins], rre[kStftBins], rim[kStftBins];
        vDSP_vmul(mic_, 1, window_, 1, frame, 1, kStftSize);
        fft_.forward(frame, mre, mim);
        vDSP_vmul(ref_, 1, window_, 1, frame, 1, kStftSize);
        fft_.forward(frame, rre, rim);

        float raw[kStftBins];
        for (int b = 0; b < kStftBins; b++) {
            float pm = mre[b] * mre[b] + mim[b] * mim[b];
            float pr = rre[b] * rre[b] + rim[b] * rim[b];
            if (pr > 1e-9f) {
                float ratio = pm / (pr + 1e-12f);
                // track the coupling from below so the voice doesn't inflate it
                coupling_[b] += (ratio - coupling_[b]) * (ratio < coupling_[b] ? down_ : up_);
            }
            float echo = coupling_[b] * pr;
            raw[b] = std::clamp(1.f - kOver * echo / (pm + 1e-12f), kFloor, 1.f);
        }
        for (int b = 0; b < kStftBins; b++) {  // 5-bin moving average across frequency
            float s = 0; int n = 0;
            for (int j = std::max(0, b - 2); j <= std::min(kStftBins - 1, b + 2); j++) { s += raw[j]; n++; }
            gain_[b] = smooth_ * gain_[b] + (1 - smooth_) * (s / n);
            mre[b] *= gain_[b];
            mim[b] *= gain_[b];
        }

        fft_.inverse(mre, mim, frame);
        vDSP_vmul(frame, 1, window_, 1, frame, 1, kStftSize);
        float half = 0.5f;  // sqrt-Hann analysis * synthesis = Hann, which sums to 2 at 75% overlap
        vDSP_vsmul(frame, 1, &half, frame, 1, kStftSize);
        std::memmove(ola_, ola_ + kStftHop, sizeof(float) * (kStftSize - kStftHop));
        std::fill(ola_ + kStftSize - kStftHop, ola_ + kStftSize, 0.f);
        vDSP_vadd(ola_, 1, frame, 1, ola_, 1, kStftSize);
        std::memcpy(out, ola_, sizeof(float) * kStftHop);
    }

    float coupling_[kStftBins];

private:
    static void shift_in(float *buf, const float *x) {
        std::memmove(buf, buf + kStftHop, sizeof(float) * (kStftSize - kStftHop));
        std::memcpy(buf + kStftSize - kStftHop, x, sizeof(float) * kStftHop);
    }

    static constexpr float kOver = 2.0f, kFloor = 0.05f;
    RealFft fft_;
    float window_[kStftSize], mic_[kStftSize] = {}, ref_[kStftSize] = {}, ola_[kStftSize] = {};
    float gain_[kStftBins];
    float smooth_, down_, up_;
};

std::vector<float> highpass_complement(const std::vector<float> &lp) {
    std::vector<float> hp(lp.size());
    for (size_t i = 0; i < lp.size(); i++) hp[i] = -lp[i];
    hp[lp.size() / 2] += 1;
    return hp;
}

std::vector<float> bandpass(double lo, double hi) {
    auto a = lowpass(kCrossTaps, hi, false), b = lowpass(kCrossTaps, lo, false);
    for (size_t i = 0; i < a.size(); i++) a[i] -= b[i];
    return a;
}

}  // namespace

// ---------- full pipeline ----------

struct NeuralAec {
    NaecOptions opt;
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "stream-audio"};
    std::unique_ptr<Dtln> dtln;
    HighBandGate gate;

    // 48k -> 16k -> DTLN -> 48k
    Fir down_mic{lowpass(kResampleTaps, 8000, true)}, down_ref{lowpass(kResampleTaps, 8000, true)};
    Fir up{lowpass(kResampleTaps, 8000, true)};
    int phase = 0;

    // Everything the high band uses is delayed to line up with DTLN's output.
    static constexpr int kLowDelay = 2 * (kResampleTaps / 2) + 3 * Dtln::kLatency16;  // 60 + 1152
    DelayLine mic_delay{kLowDelay};
    DelayLine ref_delay{0};
    Fir lp{lowpass(kCrossTaps, 7500, false)};
    Fir hp_mic{highpass_complement(lowpass(kCrossTaps, 7500, false))};
    Fir hp_ref{highpass_complement(lowpass(kCrossTaps, 7500, false))};
    Fir band_in{bandpass(3000, 7500)}, band_out{bandpass(3000, 7500)};
    DelayLine low_gate_delay{HighBandGate::kLatency};  // low band waits for the STFT gate
    float steer_level = 0, steer_prev = 0;

    // gate input/output staging (gate runs in kStftHop chunks)
    float gate_mic[kHop], gate_ref[kHop], gate_out[kHop];
};

extern "C" NeuralAec *naec_create(const char *model_prefix, NaecOptions options, char *error, int error_len) {
    try {
        auto aec = std::make_unique<NeuralAec>();
        aec->opt = options;
        aec->dtln = std::make_unique<Dtln>(aec->env, model_prefix);
        int acoustic = int(options.acoustic_delay_ms * kRate / 1000);
        aec->ref_delay = DelayLine(NeuralAec::kLowDelay + acoustic);
        return aec.release();
    } catch (const std::exception &e) {
        if (error && error_len > 0) snprintf(error, error_len, "%s", e.what());
        return nullptr;
    }
}

extern "C" void naec_destroy(NeuralAec *aec) { delete aec; }

extern "C" int naec_hop(void) { return kHop; }

extern "C" int naec_latency(const NeuralAec *aec) {
    int lat = NeuralAec::kLowDelay + kCrossTaps / 2;
    if (aec->opt.high_band == 2) lat += HighBandGate::kLatency;
    return lat;
}

extern "C" void naec_process(NeuralAec *a, const float *mic, const float *ref, float *out) {
    // 1. decimate to 16 kHz and run DTLN on 128 new samples
    float mic16[kShift16], ref16[kShift16], low16[kShift16];
    int n16 = 0;
    for (int i = 0; i < kHop; i++) {
        float m = a->down_mic.process(mic[i]), r = a->down_ref.process(ref[i]);
        if (a->phase == 0) { mic16[n16] = m; ref16[n16] = r; n16++; }
        a->phase = (a->phase + 1) % 3;
    }
    a->dtln->process(mic16, ref16, low16);

    // 2. back to 48 kHz (zero-stuff + filter, x3 gain)
    float low[kHop];
    for (int i = 0; i < kHop; i++) low[i] = 3.f * a->up.process(i % 3 == 0 ? low16[i / 3] : 0.f);

    if (a->opt.high_band == 0) {
        for (int i = 0; i < kHop; i++) out[i] = a->lp.process(low[i]);
        return;
    }

    // 3. crossover, and how much of the mic's 3-7.5 kHz band DTLN kept this hop
    float lo[kHop], hf[kHop], hf_ref[kHop];
    double e_in = 1e-10, e_out = 1e-10;
    for (int i = 0; i < kHop; i++) {
        float md = a->mic_delay.process(mic[i]);
        lo[i] = a->lp.process(low[i]);
        hf[i] = a->hp_mic.process(md);
        hf_ref[i] = a->hp_ref.process(a->ref_delay.process(ref[i]));
        float bi = a->band_in.process(md), bo = a->band_out.process(low[i]);
        e_in += bi * bi;
        e_out += bo * bo;
    }
    float target = std::pow(std::min(float(std::sqrt(e_out / e_in)), 1.f), a->opt.steer_power);
    a->steer_level += (target - a->steer_level) * (target > a->steer_level ? 0.8f : 0.3f);
    for (int i = 0; i < kHop; i++) {
        float g = a->steer_prev + (a->steer_level - a->steer_prev) * (i + 1) / kHop;
        hf[i] *= g;
    }
    a->steer_prev = a->steer_level;

    if (a->opt.high_band == 1) {
        for (int i = 0; i < kHop; i++) out[i] = lo[i] + hf[i];
        return;
    }

    // 4. reference-aware gate on the high band; the low band waits for it
    for (int c = 0; c < kHop; c += kStftHop) a->gate.process(hf + c, hf_ref + c, a->gate_out + c);
    for (int i = 0; i < kHop; i++) out[i] = a->low_gate_delay.process(lo[i]) + a->gate_out[i];
}

namespace {
constexpr char kMagic[8] = {'N', 'A', 'E', 'C', 'S', 'T', '0', '1'};
}

extern "C" int naec_save_state(const NeuralAec *a, const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fwrite(kMagic, 1, 8, f);
    fwrite(a->dtln->state1_, sizeof(float), kStateSize, f);
    fwrite(a->dtln->state2_, sizeof(float), kStateSize, f);
    fwrite(a->gate.coupling_, sizeof(float), kStftBins, f);
    fclose(f);
    return 0;
}

extern "C" int naec_load_state(NeuralAec *a, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    char magic[8];
    bool ok = fread(magic, 1, 8, f) == 8 && std::memcmp(magic, kMagic, 8) == 0 &&
              fread(a->dtln->state1_, sizeof(float), kStateSize, f) == size_t(kStateSize) &&
              fread(a->dtln->state2_, sizeof(float), kStateSize, f) == size_t(kStateSize) &&
              fread(a->gate.coupling_, sizeof(float), kStftBins, f) == size_t(kStftBins);
    fclose(f);
    if (!ok) a->dtln->reset();
    return ok ? 0 : -1;
}
