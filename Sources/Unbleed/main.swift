// Unbleed: removes game/system audio from a microphone in real time, using the Mac's own system
// output as the echo reference. Default engine is the DTLN-aec neural canceller; WebRTC AEC3 is available.
import AppKit
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
Brand.migrateFromStreamAudio()
if CommandLine.arguments.dropFirst().first == "--keepalive-child" { KeepAliveHelper.runChild() }

let usage = """
usage: unbleed [options]
  --mic NAME            input device (substring match)         default: macOS's default input
  --mic-channel N       channel of the mic to use (0-based)    default: 0
  --output NAME         output device for the cleaned mic, e.g. "Unbleed Mic"
  --desktop-output NAME output device for everything the Mac plays except this app, delayed to stay
                        in sync with the cleaned mic, e.g. "Unbleed Desktop"
  --engine NAME         neural or webrtc                       default: neural
  --delay MS            starting speaker-to-mic delay (then measured live)  default: 80

 neural engine:
  --high-band MODE      above 8 kHz: refaware, steered, or none (DTLN only)   default: refaware
  --model PREFIX        model files PREFIX_1.onnx / PREFIX_2.onnx  default: bundled DTLN-aec 512
  --state PATH          where learned state is saved/loaded    default: ~/Library/Application Support/Unbleed/state.bin
  --no-state            start fresh and don't save

 webrtc engine:
  --suppression LIST    comma-separated: full, light, off, or a number (transparency multiplier;
                        1 = stock AEC3, higher lets more voice through). First one goes to --output.
                                                               default: light
  --noise LEVEL         noise suppression: off, low, moderate, high   default: off

  --compare             run neural (refaware) and webrtc (16) side by side; neural feeds --output
  --record PATH         record a WAV: raw mic, system audio, then each processor's output
  --duration SECONDS    stop after this long (required with --record)
  --list-devices        print audio devices and exit
"""

// Launched from Finder, the Dock or Login Items there are no arguments: use the saved setup and report
// problems in a dialog, since there's no terminal to print to.
let launchedWithoutArguments = CommandLine.arguments.dropFirst().allSatisfy { $0.hasPrefix("-psn_") }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    Log.write("error: \(message)", echo: false)
    if launchedWithoutArguments {
        NSApplication.shared.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "\(Brand.name) couldn't start"
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
    exit(1)
}

var options: [String: String] = [:]
var argv = launchedWithoutArguments ? ArraySlice(LaunchConfig.arguments()) : CommandLine.arguments.dropFirst()
while let arg = argv.popFirst() {
    switch arg {
    case "--list-devices", "-h", "--help", "--no-state", "--compare": options[arg] = ""
    case "--mic", "--mic-channel", "--output", "--suppression", "--noise", "--delay", "--record", "--duration",
         "--engine", "--high-band", "--model", "--state", "--desktop-output":
        guard let value = argv.popFirst() else { fail("\(arg) needs a value") }
        options[arg] = value
    default: fail("unknown option \(arg)\n\(usage)")
    }
}

if options["-h"] != nil || options["--help"] != nil { print(usage); exit(0) }
if options["--list-devices"] != nil {
    for d in AudioDevice.all() {
        print("\(d.name)  [in \(d.inputChannels), out \(d.outputChannels)]")
    }
    exit(0)
}

let engineName = options["--engine"] ?? "neural"
guard ["neural", "webrtc"].contains(engineName) else { fail("bad --engine value") }
let presets: [String: Float] = ["full": 1, "light": 4, "off": 10_000]
let suppression: [(name: String, transparency: Float)] = (options["--suppression"] ?? "light").split(separator: ",").map { item in
    let name = String(item)
    guard let t = presets[name] ?? Float(name), t >= 1 else { fail("bad --suppression value '\(name)'") }
    return (name, t)
}
let highBands: [String: Int32] = ["none": 0, "steered": 1, "refaware": 2]
guard let highBand = highBands[options["--high-band"] ?? "refaware"] else { fail("bad --high-band value") }
let modelPrefix = options["--model"] ?? (Bundle.main.resourcePath ?? ".") + "/models/dtln_aec_512"
let statePath: String? = options["--no-state"] != nil ? nil : options["--state"]
    ?? Brand.statePath
let noiseLevels: [String: Int32] = ["off": -1, "low": 0, "moderate": 1, "high": 2]
guard let noise = noiseLevels[options["--noise"] ?? "off"] else { fail("bad --noise value") }
let delay = Int32(options["--delay"] ?? "80") ?? 80
let micChannel = Int(options["--mic-channel"] ?? "0") ?? 0
let duration = options["--duration"].flatMap(Double.init)
let recordPath = options["--record"]
if recordPath != nil && duration == nil { fail("--record needs --duration") }

/// macOS's default input, unless that's one of our own virtual devices; then the first real mic.
func systemDefaultMic() -> AudioDevice? {
    var id = AudioDeviceID(0)
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
    let inputs = AudioDevice.all().filter { $0.inputChannels > 0 && !Brand.isOwnDevice(name: $0.name, uid: $0.uid) }
    return inputs.first { $0.id == id } ?? inputs.first
}

var micNote = ""  // shown in the menu when we had to fall back
let mic: AudioDevice
if let name = options["--mic"] {
    if let found = AudioDevice.find(name, input: true) {
        mic = found
    } else if launchedWithoutArguments, let fallback = systemDefaultMic() {
        // the saved mic is off or unplugged: start anyway rather than leave the stream without a voice
        mic = fallback
        micNote = "\(name) not found — using \(fallback.name)"
        Log.write(micNote)
    } else {
        fail("mic '\(name)' not found; try --list-devices")
    }
} else if let found = systemDefaultMic() {
    mic = found
} else {
    fail("no microphone found")
}
func outputDevice(_ option: String) -> AudioDevice? {
    guard let name = options[option] else { return nil }
    guard let found = AudioDevice.find(name, input: false) else { fail("\(option) '\(name)' not found") }
    return found
}
let output = outputDevice("--output")
let desktopOutput = outputDevice("--desktop-output")
if let output, let desktopOutput, output.uid == desktopOutput.uid { fail("--output and --desktop-output must differ") }

// Two copies would both write to the same output devices and double your voice in OBS.
if NSRunningApplication.runningApplications(withBundleIdentifier: Brand.bundleID).count > 1 {
    fail("\(Brand.name) is already running — look for its icon in the menu bar.")
}

let supervisor: Supervisor
do {
    // all processing runs at the mic's rate; the neural model needs 48 kHz
    var rateAddr = address(kAudioDevicePropertyNominalSampleRate)
    var micRate = Float64(0)
    var rateSize = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(mic.id, &rateAddr, 0, nil, &rateSize, &micRate)
    func neural() throws -> Processor {
        guard micRate == 48000 else {
            throw CoreAudioError(what: "neural engine needs 48 kHz; the mic runs at \(Int(micRate)) Hz", status: -1)
        }
        let name = ["none": "dtln", "steered": "dtln+steered", "refaware": "dtln+refaware"][options["--high-band"] ?? "refaware"]!
        return try NeuralProcessor(name: name, modelPrefix: modelPrefix, highBand: highBand,
                                   acousticDelayMs: Float(delay), statePath: statePath)
    }
    func webrtc(_ name: String, _ transparency: Float) throws -> Processor {
        try WebRTCProcessor(name: "webrtc " + name, transparency: transparency, sampleRate: micRate,
                            noiseSuppression: noise, delayMs: delay)
    }
    let processors: [Processor]
    if options["--compare"] != nil {
        // WebRTC uses 10 ms frames; run it on the neural hop by giving both the same input in an adapter
        processors = [try neural(), HopAdapter(try webrtc("16", 16), hop: Int(naec_hop()))]
    } else if engineName == "neural" {
        processors = [try neural()]
    } else {
        processors = try suppression.map { try webrtc($0.name, $0.transparency) }
    }
    supervisor = try Supervisor(mic: mic, output: output, desktopOutput: desktopOutput, micChannel: micChannel,
                                processors: processors, recordSeconds: duration)
} catch {
    fail("\(error)")
}
var engine: Engine { supervisor.engine }
var device: CaptureDevice { supervisor.device }

Log.write("started: mic \(mic.name), output \(output?.name ?? "none"), desktop \(desktopOutput?.name ?? "none"), "
          + "processing \(supervisor.processors.map(\.name).joined(separator: ", "))", echo: false)

print("mic: \(mic.name) (channel \(micChannel)), output: \(output?.name ?? "none"), \(Int(device.sampleRate)) Hz")
if let desktopOutput {
    print("desktop mix -> \(desktopOutput.name), delayed \(engine.desktopDelay * 1000 / Int(device.sampleRate)) ms to match the mic")
}
print("processing: \(engine.processors.map(\.name).joined(separator: ", "))")
print("running — ctrl-c to stop (log: \(Log.path))")

func db(_ squares: Double, _ n: Int) -> String {
    String(format: "%6.1f", 10 * log10(squares / Double(max(n, 1)) + 1e-12))
}

let started = Date()
nonisolated(unsafe) var ticks = 0
nonisolated(unsafe) var lastRoomDelay = -1
NSApplication.shared.setActivationPolicy(.accessory)
let routing = "\(mic.name) → \(output?.name ?? "no output")"
let menuBar = MenuBar(
    routing: routing,
    currentMic: { supervisor.micUID },
    onSelectMic: { mic in
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(mic.id, &addr, 0, nil, &size, &rate)
        if engineName == "neural" && rate != 48000 {
            let alert = NSAlert()
            alert.messageText = "Can't use \(mic.name)"
            alert.informativeText = "It runs at \(Int(rate)) Hz; the neural canceller needs 48 kHz. "
                + "Set it to 48000 Hz in Audio MIDI Setup and try again."
            NSApp.activate()
            alert.runModal()
            return
        }
        Log.write("microphone → \(mic.name)")
        micNote = ""
        supervisor.useMic(mic)
        LaunchConfig.setOption("--mic", mic.name)
    },
    readLevels: {
        func level(_ squares: Double, _ n: Int) -> Float { n == 0 ? -120 : Float(10 * log10(squares / Double(n) + 1e-12)) }
        let e = engine
        let l = Levels(mic: level(e.uiMic, e.uiSamples), game: level(e.uiRef, e.uiSamples), out: level(e.uiOut, e.uiSamples))
        e.uiMic = 0; e.uiRef = 0; e.uiOut = 0; e.uiSamples = 0
        return l
    },
    onQuit: { shutdown() })

let meter = Timer(timeInterval: 1, repeats: true) { _ in
    supervisor.tick()
    ticks += 1
    let n = engine.meterSamples
    if let neural = engine.processors.first as? NeuralProcessor {
        let room = Int(neural.acousticDelayMs.rounded())
        if room != lastRoomDelay {
            if lastRoomDelay >= 0 { Log.write("speaker→mic delay measured: \(room) ms") }
            lastRoomDelay = room
        }
    }
    let recovered = supervisor.recoveries > 0 ? " · \(supervisor.recoveries) recover\(supervisor.recoveries == 1 ? "y" : "ies")" : ""
    if n == 0 {
        menuBar.update(status: "Waiting for audio — is the mic on?\(recovered)", healthy: false)
        print("no audio arriving yet (is the mic on?) | \(engine.processors[0].status())")
        if let duration, Date().timeIntervalSince(started) >= duration { shutdown() }
        return
    }
    let line = "mic \(db(engine.micSquares, n)) dB | game \(db(engine.refSquares, n)) dB | out \(db(engine.outSquares, n)) dB | \(engine.processors[0].status())"
    print(line)
    let status = micNote.isEmpty
        ? "Removing game audio · \(engine.processors[0].latency * 1000 / 48000 + 8) ms\(lastRoomDelay > 0 ? " · room \(lastRoomDelay) ms" : "")\(recovered)"
        : micNote
    menuBar.update(status: status, healthy: micNote.isEmpty)
    if ticks % 10 == 0 { Log.write(line, echo: false) }
    engine.micSquares = 0; engine.refSquares = 0; engine.outSquares = 0; engine.meterSamples = 0
    if let duration, Date().timeIntervalSince(started) >= duration { shutdown() }
}
RunLoop.main.add(meter, forMode: .common)

@Sendable func writeRecording(to path: String) {
    guard let samples = engine.recording, engine.recorded > 0 else { return }
    let channels = engine.recordChannels
    // More than two channels needs an explicit layout or AVAudioFormat returns nil.
    guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return }
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: device.sampleRate,
                               interleaved: true, channelLayout: layout)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(engine.recorded)) else {
        print("could not write recording: buffer allocation failed")
        return
    }
    buffer.frameLength = AVAudioFrameCount(engine.recorded)
    buffer.audioBufferList.pointee.mBuffers.mData!.copyMemory(from: samples, byteCount: engine.recorded * channels * 4)
    do {
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: true)
        try file.write(from: buffer)
    } catch {
        print("could not write recording: \(error)")
        return
    }
    let names = ["raw mic", "system audio"] + engine.processors.map(\.name)
    print("recorded \(path): " + names.enumerated().map { "ch\($0.offset + 1) \($0.element)" }.joined(separator: ", "))
}

func shutdown() -> Never {
    supervisor.stop()
    supervisor.processors.forEach { $0.finish() }
    if let recordPath { writeRecording(to: recordPath) }
    supervisor.destroy()
    Log.write("stopped", echo: false)
    exit(0)
}

nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGUSR1] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    // SIGUSR1 forces a capture rebuild (pkill -USR1 -f Unbleed.app) — for testing recovery
    source.setEventHandler {
        if sig == SIGUSR1 { supervisor.recover("rebuild requested (SIGUSR1)") } else { shutdown() }
    }
    source.resume()
    signalSources.append(source)
}

NSApp.run()
