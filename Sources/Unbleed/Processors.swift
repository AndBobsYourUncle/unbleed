import Foundation

/// Removes system audio from the mic, one fixed-size hop at a time, on the audio thread.
protocol Processor: AnyObject {
    var name: String { get }
    var hop: Int { get }
    /// Delay of the output relative to the input, in samples (beyond the engine's hop buffering).
    var latency: Int { get }
    func process(mic: UnsafePointer<Float>, ref: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>)
    /// One-line status for the meter, called from the main thread.
    func status() -> String
    func finish()
}

/// WebRTC AEC3 with a given suppression transparency (10 ms frames).
final class WebRTCProcessor: Processor {
    let name: String
    let hop: Int
    let latency = 432  // measured: AEC3's output trails its input by ~9 ms
    private let aec: OpaquePointer

    init(name: String, transparency: Float, sampleRate: Double, noiseSuppression: Int32, delayMs: Int32) throws {
        self.name = name
        hop = Int(sampleRate) / 100
        let options = AecOptions(sample_rate: Int32(sampleRate), transparency: transparency,
                                 noise_suppression: noiseSuppression, high_pass_filter: 1, initial_delay_ms: delayMs)
        guard let aec = aec_create(options) else {
            throw CoreAudioError(what: "create echo canceller '\(name)'", status: -1)
        }
        self.aec = aec
    }

    deinit { aec_destroy(aec) }

    func process(mic: UnsafePointer<Float>, ref: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
        out.update(from: mic, count: hop)
        aec_process_render(aec, ref)
        aec_process_capture(aec, out)
    }

    func status() -> String {
        let s = aec_stats(aec)
        return "ERLE \(s.erle_db.isNaN ? "-" : String(format: "%.0f", s.erle_db)) dB, delay \(s.delay_ms) ms"
    }

    func finish() {}
}

/// DTLN-aec neural canceller with the steered / reference-aware high band (48 kHz, 8 ms hops).
final class NeuralProcessor: Processor {
    let name: String
    let hop = Int(naec_hop())
    let latency: Int
    private let aec: OpaquePointer
    private let statePath: String?

    init(name: String, modelPrefix: String, highBand: Int32, acousticDelayMs: Float, statePath: String?) throws {
        self.name = name
        self.statePath = statePath
        var error = [CChar](repeating: 0, count: 512)
        let options = NaecOptions(high_band: highBand, steer_power: 2, acoustic_delay_ms: acousticDelayMs)
        guard let aec = naec_create(modelPrefix, options, &error, Int32(error.count)) else {
            throw CoreAudioError(what: "load neural model '\(modelPrefix)': \(String(cString: error))", status: -1)
        }
        self.aec = aec
        latency = Int(naec_latency(aec))
        if let statePath, naec_load_state(aec, statePath) == 0 {
            print("loaded learned state from \(statePath)")
        }
    }

    deinit { naec_destroy(aec) }

    func process(mic: UnsafePointer<Float>, ref: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
        naec_process(aec, mic, ref, out)
    }

    /// Speaker→mic delay the high band is using (measured live).
    var acousticDelayMs: Float { naec_acoustic_delay_ms(aec) }

    func status() -> String {
        "neural, latency \(latency * 1000 / 48000 + hop * 1000 / 48000) ms, room \(Int(acousticDelayMs.rounded())) ms"
    }

    func finish() {
        guard let statePath else { return }
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        if naec_save_state(aec, statePath) == 0 { print("saved learned state to \(statePath)") }
    }
}

/// Runs a processor with a different hop size by buffering; adds `inner.hop` samples of latency.
final class HopAdapter: Processor {
    let hop: Int
    var name: String { inner.name }
    var latency: Int { inner.latency + inner.hop }
    private let inner: Processor
    private let size: Int
    private let micBuf, refBuf, outBuf, work: UnsafeMutablePointer<Float>
    private var fill = 0
    private var outRead = 0, outWrite: Int

    init(_ inner: Processor, hop: Int) {
        self.inner = inner
        self.hop = hop
        size = 4 * (inner.hop + hop)
        micBuf = .allocate(capacity: inner.hop); refBuf = .allocate(capacity: inner.hop)
        work = .allocate(capacity: inner.hop)
        outBuf = .allocate(capacity: size); outBuf.initialize(repeating: 0, count: size)
        outWrite = inner.hop  // prefill so output never runs dry
    }

    deinit { micBuf.deallocate(); refBuf.deallocate(); work.deallocate(); outBuf.deallocate() }

    func process(mic: UnsafePointer<Float>, ref: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>) {
        for i in 0..<hop {
            micBuf[fill] = mic[i]; refBuf[fill] = ref[i]
            fill += 1
            if fill == inner.hop {
                inner.process(mic: micBuf, ref: refBuf, out: work)
                for j in 0..<inner.hop { outBuf[outWrite] = work[j]; outWrite = (outWrite + 1) % size }
                fill = 0
            }
        }
        for i in 0..<hop { out[i] = outBuf[outRead]; outRead = (outRead + 1) % size }
    }

    func status() -> String { inner.status() }
    func finish() { inner.finish() }
}
