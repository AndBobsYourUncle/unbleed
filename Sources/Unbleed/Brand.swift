import Foundation

/// Names, identifiers and file locations in one place.
enum Brand {
    static let name = "Unbleed"
    static let bundleID = "dev.unbleed.app"
    static let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"

    /// Unbleed's own virtual devices (drivers/build_drivers.sh).
    static let micDevice = "Unbleed Mic"
    static let desktopDevice = "Unbleed Desktop"

    static let supportDir = NSHomeDirectory() + "/Library/Application Support/Unbleed"
    static let configPath = supportDir + "/config"
    static let statePath = supportDir + "/state.bin"
    static let logPath = NSHomeDirectory() + "/Library/Logs/Unbleed.log"
    static let aggregatePrefix = "dev.unbleed.aggregate"

    /// Devices that are Unbleed's own plumbing, never a microphone to offer.
    static func isOwnDevice(name: String, uid: String) -> Bool {
        name.hasPrefix("Unbleed ") || name.contains("BlackHole") || uid.hasPrefix(aggregatePrefix)
    }

    /// One-time move from the pre-rename locations (stream-audio) so learned state and settings survive.
    static func migrateFromStreamAudio() {
        let fm = FileManager.default
        let old = NSHomeDirectory() + "/Library/Application Support/stream-audio"
        guard fm.fileExists(atPath: old), !fm.fileExists(atPath: supportDir) else { return }
        try? fm.moveItem(atPath: old, toPath: supportDir)
        let oldLog = NSHomeDirectory() + "/Library/Logs/stream-audio.log"
        if fm.fileExists(atPath: oldLog), !fm.fileExists(atPath: logPath) { try? fm.moveItem(atPath: oldLog, toPath: logPath) }
    }
}
