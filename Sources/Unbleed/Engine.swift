import CoreAudio
import Foundation

/// Runs on the Core Audio IO thread: gathers mic + system audio into hops, runs the processors, and
/// writes the result to the output device and/or a recording. Everything is preallocated.
/// Several processors can run side by side on the same input for A/B tests; the first feeds the output.
final class Engine: @unchecked Sendable {
    let device: CaptureDevice
    let frame: Int
    let micChannel: Int
    let processors: [Processor]

    // Partially filled hop.
    private let micFrame: UnsafeMutablePointer<Float>
    private let refFrame: UnsafeMutablePointer<Float>
    private let work: UnsafeMutablePointer<Float>
    private var fill = 0

    // Processed audio waiting to be written to the output device.
    private let ringSize = 8192
    private let ring: UnsafeMutablePointer<Float>
    private var ringRead = 0
    private var ringWrite = 0

    // Desktop mix (stereo tap) delayed to line up with the processed mic: same input, same delay.
    private let deskSize = 1 << 15
    private let desk: UnsafeMutablePointer<Float>
    private var deskWrite = 0
    let desktopDelay: Int

    // Recording: channel 0 raw mic, 1 system audio, then one channel per processor.
    let recordChannels: Int
    let recordCapacity: Int
    let recording: UnsafeMutablePointer<Float>?
    private(set) var recorded = 0

    // Meters, read by the main thread once a second (benign races).
    var micSquares: Double = 0
    var refSquares: Double = 0
    var outSquares: Double = 0
    var meterSamples = 0
    // Separate accumulators for the menu's live meters (read and reset ~15x a second while it's open).
    var uiMic: Double = 0, uiRef: Double = 0, uiOut: Double = 0
    var uiSamples = 0
    /// Incremented by every IO callback; the supervisor watches it to detect stalls.
    var callbacks = 0

    private var procID: AudioDeviceIOProcID?

    init(device: CaptureDevice, micChannel: Int, processors: [Processor], recordSeconds: Double?) throws {
        precondition(!processors.isEmpty && processors.allSatisfy { $0.hop == processors[0].hop },
                     "processors must share a hop size")
        self.device = device
        self.micChannel = micChannel
        self.processors = processors
        frame = processors[0].hop
        // the mic path is delayed by one hop of ring headroom plus the processor's own latency
        desktopDelay = frame + processors[0].latency
        desk = .allocate(capacity: deskSize * 2)
        desk.initialize(repeating: 0, count: deskSize * 2)

        micFrame = .allocate(capacity: frame)
        refFrame = .allocate(capacity: frame)
        work = .allocate(capacity: frame)
        ring = .allocate(capacity: ringSize)
        ring.initialize(repeating: 0, count: ringSize)
        ringWrite = frame  // one frame of headroom so the output never runs dry

        recordChannels = 2 + processors.count
        if let seconds = recordSeconds {
            recordCapacity = Int(seconds * device.sampleRate)
            recording = .allocate(capacity: recordCapacity * recordChannels)
        } else {
            recordCapacity = 0
            recording = nil
        }
    }

    deinit {
        micFrame.deallocate(); refFrame.deallocate(); work.deallocate(); ring.deallocate(); desk.deallocate()
        recording?.deallocate()
    }

    func start() throws {
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.aggregateID, nil) { [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }, "create IO proc")
        try check(AudioDeviceStart(device.aggregateID, procID), "start audio")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(device.aggregateID, procID)
        AudioDeviceDestroyIOProcID(device.aggregateID, procID)
        self.procID = nil
    }


    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        callbacks &+= 1
        let micIndex = device.micInputBuffer
        guard inputs.count >= 2, micIndex < inputs.count - 1,
              let micData = inputs[micIndex].mData, let tapData = inputs[inputs.count - 1].mData else { return }
        // Taps come after all subdevice streams, so the system audio is the last buffer.
        let mic = micData.assumingMemoryBound(to: Float.self)
        let tap = tapData.assumingMemoryBound(to: Float.self)
        let micChannels = Int(inputs[micIndex].mNumberChannels)
        let tapChannels = Int(inputs[inputs.count - 1].mNumberChannels)
        let frames = Int(inputs[micIndex].mDataByteSize) / (4 * micChannels)
        let channel = min(micChannel, micChannels - 1)

        for i in 0..<frames {
            micFrame[fill] = mic[i * micChannels + channel]
            var sum: Float = 0
            for c in 0..<tapChannels { sum += tap[i * tapChannels + c] }
            refFrame[fill] = sum / Float(tapChannels)
            fill += 1
            if fill == frame {
                processFrame()
                fill = 0
            }
        }

        // Processed mic to every channel of the mic output; the delayed stereo desktop mix to the first
        // two channels of the desktop output. Silence if the mic ring ever runs short.
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var available = (ringWrite - ringRead + ringSize) % ringSize
        for i in 0..<frames {
            var sample: Float = 0
            if available > 0 {
                sample = ring[ringRead]
                ringRead = (ringRead + 1) % ringSize
                available -= 1
            }
            let left = tap[i * tapChannels], right = tap[i * tapChannels + min(1, tapChannels - 1)]
            desk[deskWrite * 2] = left
            desk[deskWrite * 2 + 1] = right
            let deskRead = (deskWrite - desktopDelay + deskSize) % deskSize
            deskWrite = (deskWrite + 1) % deskSize

            for (index, buffer) in outputs.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(buffer.mNumberChannels)
                guard i < Int(buffer.mDataByteSize) / (4 * n) else { continue }
                if device.micOutputBuffers.contains(index) {
                    for c in 0..<n { data[i * n + c] = sample }
                } else if device.desktopOutputBuffers.contains(index) {
                    for c in 0..<n { data[i * n + c] = c < 2 ? desk[deskRead * 2 + c] : 0 }
                }
            }
        }
    }

    private func processFrame() {
        let recordBase = recording.map { $0 + recorded * recordChannels }
        let canRecord = recorded + frame <= recordCapacity

        for (index, processor) in processors.enumerated() {
            processor.process(mic: micFrame, ref: refFrame, out: work)
            if index == 0 {
                for i in 0..<frame {
                    ring[ringWrite] = work[i]
                    ringWrite = (ringWrite + 1) % ringSize
                    outSquares += Double(work[i] * work[i])
                    uiOut += Double(work[i] * work[i])
                }
            }
            if canRecord, let base = recordBase {
                for i in 0..<frame { base[i * recordChannels + 2 + index] = work[i] }
            }
        }

        for i in 0..<frame {
            micSquares += Double(micFrame[i] * micFrame[i])
            refSquares += Double(refFrame[i] * refFrame[i])
            uiMic += Double(micFrame[i] * micFrame[i])
            uiRef += Double(refFrame[i] * refFrame[i])
        }
        meterSamples += frame
        uiSamples += frame

        if canRecord, let base = recordBase {
            for i in 0..<frame {
                base[i * recordChannels] = micFrame[i]
                base[i * recordChannels + 1] = refFrame[i]
            }
            recorded += frame
        }
    }
}
