// Installer helper: remembers and restores the default audio devices around a Core Audio restart.
//   audiodefaults save <file>             write the default output, input and system-sound device UIDs
//   audiodefaults restore <file> [secs]   wait (default 15 s) for those devices to reappear, then re-select them
// Without this, macOS falls back to whichever device comes back first after the restart (usually the
// built-in speakers rather than an external display or interface).
import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)
let roles: [(String, AudioObjectPropertySelector)] = [
    ("output", kAudioHardwarePropertyDefaultOutputDevice),
    ("input", kAudioHardwarePropertyDefaultInputDevice),
    ("system", kAudioHardwarePropertyDefaultSystemOutputDevice),
]

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func uid(of device: AudioDeviceID) -> String? {
    var addr = address(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func current(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var addr = address(selector)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
    return id
}

func device(withUID target: String) -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    return ids.first { uid(of: $0) == target }
}

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: audiodefaults save|restore <file> [seconds]"); exit(2) }

switch args[1] {
case "save":
    let lines = roles.compactMap { role, selector in uid(of: current(selector)).map { "\(role)=\($0)" } }
    try lines.joined(separator: "\n").write(toFile: args[2], atomically: true, encoding: .utf8)

case "restore":
    guard let text = try? String(contentsOfFile: args[2], encoding: .utf8) else { exit(0) }
    var wanted: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        if parts.count == 2 { wanted[parts[0]] = parts[1] }
    }
    let deadline = Date().addingTimeInterval(Double(args.count > 3 ? args[3] : "15") ?? 15)
    var pending = roles.filter { wanted[$0.0] != nil }
    while !pending.isEmpty && Date() < deadline {
        pending = pending.filter { role, selector in
            guard let target = device(withUID: wanted[role]!) else { return true }  // not back yet
            if current(selector) != target {
                var addr = address(selector)
                var id = target
                AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
            }
            return current(selector) != target
        }
        if !pending.isEmpty { Thread.sleep(forTimeInterval: 0.25) }
    }
    if !pending.isEmpty { print("could not restore: \(pending.map(\.0).joined(separator: ", "))") }

default:
    print("usage: audiodefaults save|restore <file> [seconds]")
    exit(2)
}
