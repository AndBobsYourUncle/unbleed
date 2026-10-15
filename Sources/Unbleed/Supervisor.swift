import CoreAudio
import Foundation

/// Timestamped messages to the terminal and ~/Library/Logs/Unbleed.log, so problems that happen
/// mid-stream can be diagnosed afterwards.
enum Log {
    static let path = Brand.logPath
    private static let file: FileHandle? = {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        return handle
    }()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// `echo: false` writes to the log file only.
    static func write(_ message: String, echo: Bool = true) {
        if echo { print(message) }
        file?.write("\(stamp.string(from: Date()))  \(message)\n".data(using: .utf8)!)
    }
}

/// Owns the capture setup and rebuilds it when the audio system changes underneath it (sample-rate
/// switches, default output changes, devices disappearing) or when audio stops arriving. Processors
/// are kept across rebuilds, so the canceller doesn't have to re-learn.
final class Supervisor {
    private(set) var micUID: String
    private let outputUID: String?, desktopUID: String?
    private let micChannel: Int
    let processors: [Processor]
    private let recordSeconds: Double?

    private(set) var device: CaptureDevice
    private(set) var engine: Engine
    private var keepAlive: KeepAliveHelper
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Bumped on every rebuild. Core Audio can't always match a Swift block for removal, so listeners
    /// from an earlier setup may keep firing; they check this and ignore themselves.
    private var generation = 0
    private var defaultOutput: AudioDeviceID = 0

    private var lastCallbacks = -1
    private var stalledSeconds = 0
    private var lastRestart = Date()
    private var pendingReason: String?
    private(set) var recoveries = 0

    init(mic: AudioDevice, output: AudioDevice?, desktopOutput: AudioDevice?, micChannel: Int,
         processors: [Processor], recordSeconds: Double?) throws {
        micUID = mic.uid; outputUID = output?.uid; desktopUID = desktopOutput?.uid
        self.micChannel = micChannel
        self.processors = processors
        self.recordSeconds = recordSeconds
        keepAlive = try KeepAliveHelper()
        device = try CaptureDevice(mic: mic, output: output, desktopOutput: desktopOutput)
        engine = try Engine(device: device, micChannel: micChannel, processors: processors, recordSeconds: recordSeconds)
        try engine.start()
        defaultOutput = Supervisor.currentDefaultOutput()
        installListeners()
    }

    /// Called once a second from the main thread.
    func tick() {
        let callbacks = engine.callbacks
        if callbacks == lastCallbacks {
            stalledSeconds += 1
            if stalledSeconds == 3 { recover("audio stopped arriving for 3 s") }
        } else {
            stalledSeconds = 0
        }
        lastCallbacks = callbacks
    }

    /// Switch to another microphone; the capture is rebuilt, the processors keep their state.
    func useMic(_ device: AudioDevice) {
        guard device.uid != micUID else { return }
        micUID = device.uid
        recover("switched microphone to \(device.name)")
    }

    func stop() {
        removeListeners()
        engine.stop()
        keepAlive.stop()
    }

    func destroy() { device.destroy() }

    // MARK: recovery

    func recover(_ reason: String) {
        // Rebuilding itself triggers device notifications; coalesce bursts and rate-limit.
        if pendingReason != nil { return }
        pendingReason = reason
        let wait = max(0.3, 2 - Date().timeIntervalSince(lastRestart))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { self.rebuild() }
    }

    private func rebuild() {
        let reason = pendingReason ?? "unknown"
        pendingReason = nil
        Log.write("⚠️  \(reason) — rebuilding audio capture")
        removeListeners()
        engine.stop()
        device.destroy()
        lastRestart = Date()

        let devices = AudioDevice.all()
        func find(_ uid: String?) -> AudioDevice? { uid.flatMap { u in devices.first { $0.uid == u } } }
        let missing = [("mic", micUID as String?), ("output", outputUID), ("desktop output", desktopUID)]
            .filter { $0.1 != nil && find($0.1) == nil }.map(\.0)
        guard missing.isEmpty, let mic = find(micUID) else {
            Log.write("   waiting for \(missing.joined(separator: ", ")) to come back…")
            retry(reason)
            return
        }
        do {
            let newDefault = Supervisor.currentDefaultOutput()
            if newDefault != defaultOutput {  // the keep-alive plays to the default output; follow it
                keepAlive.stop()
                keepAlive = try KeepAliveHelper()
                defaultOutput = newDefault
            }
            device = try CaptureDevice(mic: mic, output: find(outputUID), desktopOutput: find(desktopUID))
            engine = try Engine(device: device, micChannel: micChannel, processors: processors, recordSeconds: recordSeconds)
            try engine.start()
            installListeners()
            recoveries += 1
            stalledSeconds = 0
            lastCallbacks = -1
            Log.write("✅ recovered (\(recoveries) so far this session)")
        } catch {
            Log.write("   rebuild failed: \(error)")
            retry(reason)
        }
    }

    private func retry(_ reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.recover(reason) }
    }

    // MARK: change notifications

    private func installListeners() {
        generation += 1
        let system = systemObject
        listen(system, kAudioHardwarePropertyDefaultOutputDevice) { [unowned self] in
            if Supervisor.currentDefaultOutput() != defaultOutput { recover("default output device changed") }
        }
        listen(system, kAudioHardwarePropertyDevices) { [unowned self] in
            // fires for harmless changes too (including our own aggregate); only act if one of ours vanished
            let uids = Set(AudioDevice.all().map(\.uid))
            for (name, uid) in [("mic", micUID as String?), ("output", outputUID), ("desktop output", desktopUID)] {
                if let uid, !uids.contains(uid) { recover("\(name) device disappeared") }
            }
        }
        // Notifications can arrive late (e.g. the previous aggregate's death after a rebuild reused its
        // ID), so each handler checks the actual state before acting.
        let speakerRate = Supervisor.sampleRate(defaultOutput)
        listen(defaultOutput, kAudioDevicePropertyNominalSampleRate) { [unowned self] in
            let rate = Supervisor.sampleRate(defaultOutput)
            if rate != speakerRate { recover("speaker sample rate changed (\(Int(speakerRate)) → \(Int(rate)) Hz)") }
        }
        let aggregate = device.aggregateID
        listen(aggregate, kAudioDevicePropertyDeviceIsAlive) { [unowned self] in
            var alive: UInt32 = 1
            var addr = address(kAudioDevicePropertyDeviceIsAlive)
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(aggregate, &addr, 0, nil, &size, &alive)
            if status != noErr || alive == 0 { recover("capture device died") }
        }
        listen(device.aggregateID, kAudioDeviceProcessorOverload) {
            Log.write("audio overload (a processing deadline was missed)", echo: false)
        }
        let tap = device.tapID
        let tapFormat = Supervisor.tapFormat(tap)
        listen(tap, kAudioTapPropertyFormat) { [unowned self] in
            let now = Supervisor.tapFormat(tap)
            if now.mSampleRate != tapFormat.mSampleRate || now.mChannelsPerFrame != tapFormat.mChannelsPerFrame {
                recover("system audio format changed (\(Int(tapFormat.mSampleRate)) → \(Int(now.mSampleRate)) Hz)")
            }
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var addr = address(selector)
        let mine = generation
        let block: AudioObjectPropertyListenerBlock = { [unowned self] _, _ in
            if mine == generation { handler() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr {
            listeners.append((object, addr, block))
        }
    }

    private func removeListeners() {
        generation += 1
        for (object, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    private static func sampleRate(_ id: AudioObjectID) -> Float64 {
        var rate = Float64(0)
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    private static func tapFormat(_ id: AudioObjectID) -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var addr = address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &format)
        return format
    }

    private static func currentDefaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id)
        return id
    }
}
