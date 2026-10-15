// Probe: does Apple's voice processing (VPIO) cancel audio played by OTHER apps?
// Usage: probe <device-name-substring> <seconds> <vp:on|off> <out.wav>
import AVFoundation
import CoreAudio

func findInputDevice(_ needle: String) -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nsize, &name) == noErr,
              let n = name?.takeRetainedValue() as String? else { continue }
        var inAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                mScope: kAudioObjectPropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var ssize: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &inAddr, 0, nil, &ssize)
        if ssize > 0 && n.localizedCaseInsensitiveContains(needle) { return id }
    }
    return nil
}

let args = CommandLine.arguments
guard args.count == 5, let seconds = Double(args[2]) else {
    print("usage: probe <device> <seconds> <on|off> <out.wav>"); exit(1)
}
let vpOn = args[3] == "on"

let engine = AVAudioEngine()
let input = engine.inputNode

if let dev = findInputDevice(args[1]), let au = input.audioUnit {
    var d = dev
    let err = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
    print("selected device \(dev) err=\(err)")
} else {
    print("device '\(args[1])' not found; using default input")
}

if vpOn {
    do { try input.setVoiceProcessingEnabled(true) } catch { print("VP enable failed: \(error)"); exit(1) }
    input.isVoiceProcessingAGCEnabled = false
    input.voiceProcessingOtherAudioDuckingConfiguration =
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
}

let fmt = input.outputFormat(forBus: 0)
print("input format: \(fmt)")
nonisolated(unsafe) var file: AVAudioFile? = try AVAudioFile(forWriting: URL(fileURLWithPath: args[4]), settings: fmt.settings)
input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
    try? file?.write(from: buf)
}
try engine.start()
print("recording \(seconds)s (vp=\(vpOn))")
RunLoop.main.run(until: Date().addingTimeInterval(seconds))
engine.stop()
input.removeTap(onBus: 0)
file = nil  // closes the file and finalizes the WAV header
print("done")
