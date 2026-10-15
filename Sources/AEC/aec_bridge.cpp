#include "aec_bridge.h"

#include <cmath>
#include <memory>
#include <optional>

#include "api/audio/audio_processing.h"
#include "api/audio/echo_canceller3_config.h"
#include "api/audio/echo_control.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"

namespace {

// The library doesn't ship EchoCanceller3Factory, so build AEC3 with our own config here.
class TunedAec3Factory : public webrtc::EchoControlFactory {
 public:
  explicit TunedAec3Factory(const webrtc::EchoCanceller3Config &config) : config_(config) {}

  std::unique_ptr<webrtc::EchoControl> Create(int sample_rate_hz, int num_render_channels,
                                              int num_capture_channels) override {
    return std::make_unique<webrtc::EchoCanceller3>(config_, std::nullopt, sample_rate_hz,
                                                    num_render_channels, num_capture_channels);
  }

 private:
  webrtc::EchoCanceller3Config config_;
};

// Raise the residual-echo thresholds at which the suppressor starts and finishes muting a band.
// Higher thresholds mean it only suppresses where residual echo clearly dominates the voice.
void scale(webrtc::EchoCanceller3Config::Suppressor::MaskingThresholds &m, float k) {
  m.enr_transparent *= k;
  m.enr_suppress *= k;
  m.emr_transparent *= k;
}

webrtc::EchoCanceller3Config make_config(float transparency) {
  webrtc::EchoCanceller3Config c;
  if (transparency > 1.f) {
    scale(c.suppressor.normal_tuning.mask_lf, transparency);
    scale(c.suppressor.normal_tuning.mask_hf, transparency);
    scale(c.suppressor.nearend_tuning.mask_lf, transparency);
    scale(c.suppressor.nearend_tuning.mask_hf, transparency);
    // Switch to the gentler near-end tuning sooner when the voice is present.
    c.suppressor.dominant_nearend_detection.enr_threshold /= transparency;
    c.suppressor.dominant_nearend_detection.snr_threshold /= transparency;
  }
  webrtc::EchoCanceller3Config::Validate(&c);
  return c;
}

}  // namespace

struct AecHandle {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
  int delay_ms;
};

extern "C" AecHandle *aec_create(AecOptions o) {
  webrtc::AudioProcessing::Config cfg;
  cfg.pipeline.maximum_internal_processing_rate = 48000;
  cfg.echo_canceller.enabled = true;
  cfg.echo_canceller.mobile_mode = false;
  cfg.high_pass_filter.enabled = o.high_pass_filter != 0;
  cfg.noise_suppression.enabled = o.noise_suppression >= 0;
  if (o.noise_suppression >= 0) {
    cfg.noise_suppression.level =
        static_cast<webrtc::AudioProcessing::Config::NoiseSuppression::Level>(o.noise_suppression);
  }
  cfg.gain_controller1.enabled = false;
  cfg.gain_controller2.enabled = false;

  auto apm = webrtc::AudioProcessingBuilder()
                 .SetConfig(cfg)
                 .SetEchoControlFactory(std::make_unique<TunedAec3Factory>(make_config(o.transparency)))
                 .Create();
  if (!apm) return nullptr;
  return new AecHandle{apm, webrtc::StreamConfig(o.sample_rate, 1), o.initial_delay_ms};
}

extern "C" void aec_destroy(AecHandle *aec) { delete aec; }

extern "C" int aec_process_render(AecHandle *aec, const float *render) {
  // APM hands back a copy of the render signal, which we don't need. 10 ms at up to 192 kHz.
  float scratch[1920];
  float *dest = scratch;
  return aec->apm->ProcessReverseStream(&render, aec->stream, aec->stream, &dest);
}

extern "C" int aec_process_capture(AecHandle *aec, float *capture) {
  aec->apm->set_stream_delay_ms(aec->delay_ms);
  return aec->apm->ProcessStream(&capture, aec->stream, aec->stream, &capture);
}

extern "C" AecStats aec_stats(AecHandle *aec) {
  auto s = aec->apm->GetStatistics();
  return AecStats{s.echo_return_loss_enhancement.value_or(NAN), s.delay_ms.value_or(-1)};
}
