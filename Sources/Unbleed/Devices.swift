import CoreAudio
import Foundation

let systemObject = AudioObjectID(kAudioObjectSystemObject)

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

struct AudioDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int

    static func all() -> [AudioDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(systemObject, &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioDevice(id: id, name: name, uid: uid,
                               inputChannels: channelCount(id, kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(id, kAudioObjectPropertyScopeOutput))
        }
    }

    /// First device whose name contains `needle` and has channels in the wanted direction.
    static func find(_ needle: String, input: Bool) -> AudioDevice? {
        all().first {
            $0.name.localizedCaseInsensitiveContains(needle) && (input ? $0.inputChannels : $0.outputChannels) > 0
        }
    }

    static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func channelCount(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// A tap on everything the Mac plays except this process, plus a private aggregate device that
/// clocks the mic, the tap and (optionally) virtual outputs together: one for the cleaned mic and one
/// for the desktop mix (everything the Mac plays, minus this app).
final class CaptureDevice {
    let tapID: AudioObjectID
    let aggregateID: AudioObjectID
    let sampleRate: Double
    /// Which input buffer is the mic, and which output buffers feed each output device. CoreAudio
    /// doesn't keep subdevices in the order we list them, so these come from the live layout.
    let micInputBuffer: Int
    let micOutputBuffers: Range<Int>
    let desktopOutputBuffers: Range<Int>

    init(mic: AudioDevice, output: AudioDevice?, desktopOutput: AudioDevice?) throws {
        var pid = getpid()
        var selfObject = AudioObjectID(0)
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &addr, UInt32(MemoryLayout<pid_t>.size), &pid,
                                             &size, &selfObject), "process lookup")

        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])
        tap.uuid = UUID()
        tap.name = "\(Brand.name) reference"
        tap.muteBehavior = .unmuted
        tap.isPrivate = true
        var tapID = AudioObjectID(0)
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create system audio tap")

        var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: mic.uid]]
        for device in [output, desktopOutput].compactMap({ $0 }) {
            subdevices.append([kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: true])
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Brand.name,
            kAudioAggregateDeviceUIDKey: "\(Brand.aggregatePrefix).\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: mic.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        if status != noErr {
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(what: "create aggregate device", status: status)
        }

        var rate = Float64(0)
        addr = address(kAudioDevicePropertyNominalSampleRate)
        size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &rate)

        self.tapID = tapID
        self.aggregateID = aggregateID
        self.sampleRate = rate

        // Walk the active subdevices in their real order, counting each one's streams.
        addr = address(kAudioAggregateDevicePropertyActiveSubDeviceList)
        size = 0
        AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size)
        var active = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &active)
        var inIndex = 0, outIndex = 0
        var micIn = 0
        var micOut = 0..<0, deskOut = 0..<0
        for id in active {
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID)
            let ins = AudioDevice.streamCount(id, kAudioObjectPropertyScopeInput)
            let outs = AudioDevice.streamCount(id, kAudioObjectPropertyScopeOutput)
            if uid == mic.uid { micIn = inIndex }
            if uid == output?.uid { micOut = outIndex..<(outIndex + outs) }
            if uid == desktopOutput?.uid { deskOut = outIndex..<(outIndex + outs) }
            inIndex += ins
            outIndex += outs
        }
        micInputBuffer = micIn
        micOutputBuffers = micOut
        desktopOutputBuffers = deskOut
    }

    private var destroyed = false

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit { destroy() }
}

/// Plays silence on the default output device. The system-audio tap only delivers audio while some tapped
/// process is playing, and the aggregate stalls without it. Our own process is excluded from the tap, so
/// this runs in a child process (see `KeepAliveHelper`).
final class OutputKeepAlive {
    private let deviceID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?

    init() throws {
        var id = AudioDeviceID(0)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(AudioObjectGetPropertyData(systemObject, &addr, 0, nil, &size, &id), "default output lookup")
        deviceID = id
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }, "create keep-alive")
        try check(AudioDeviceStart(deviceID, procID), "start keep-alive")
    }

    func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }

    deinit { stop() }
}

/// Runs this executable again as `--keepalive-child`, a separate process the tap can hear playing silence.
final class KeepAliveHelper {
    private let process = Process()

    init() throws {
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--keepalive-child"]
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    /// Entry point for the child: play silence until the parent goes away.
    static func runChild() -> Never {
        let parent = getppid()
        guard let keepAlive = try? OutputKeepAlive() else { exit(1) }
        while getppid() == parent { sleep(1) }
        keepAlive.stop()
        exit(0)
    }
}
