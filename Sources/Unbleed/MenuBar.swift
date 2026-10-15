import AppKit
import ServiceManagement

/// Live level readout for the menu: mic in, game, and the cleaned voice out.
struct Levels {
    var mic: Float = -120, game: Float = -120, out: Float = -120
}

/// The menu bar presence: icon, a header with status, live meters, mic picker, login toggle, about, quit.
final class MenuBar: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let header = HeaderView()
    private let meters = MetersView()
    private let routingLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let micMenu = NSMenu()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private var meterTimer: Timer?

    private let currentMic: () -> String
    private let onSelectMic: (AudioDevice) -> Void
    private let readLevels: () -> Levels
    private let onQuit: () -> Void

    init(routing: String, currentMic: @escaping () -> String, onSelectMic: @escaping (AudioDevice) -> Void,
         readLevels: @escaping () -> Levels, onQuit: @escaping () -> Void) {
        self.currentMic = currentMic
        self.onSelectMic = onSelectMic
        self.readLevels = readLevels
        self.onQuit = onQuit
        super.init()

        setIcon(healthy: true)
        menu.delegate = self

        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())
        let metersItem = NSMenuItem()
        metersItem.view = meters
        menu.addItem(metersItem)
        routingLine.title = routing
        routingLine.isEnabled = false
        menu.addItem(routingLine)
        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        micMenu.delegate = self  // rebuilt each time it opens, so newly plugged-in mics show up
        micItem.submenu = micMenu
        menu.addItem(micItem)
        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        loginItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(loginItem)
        menu.addItem(.separator())

        add("About \(Brand.name)", #selector(about), symbol: "info.circle")
        add("Open Log", #selector(openLog), symbol: "doc.text", key: "l")
        menu.addItem(.separator())
        add("Quit \(Brand.name)", #selector(quit), symbol: nil, key: "q")
        item.menu = menu
    }

    private func add(_ title: String, _ action: Selector, symbol: String?, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        if let symbol { entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(entry)
    }

    func update(status: String, healthy: Bool) {
        header.status = status
        header.healthy = healthy
        setIcon(healthy: healthy)
        item.button?.toolTip = "\(Brand.name) — \(status)"
    }

    private func setIcon(healthy: Bool) {
        let image = healthy
            ? (Bundle.main.image(forResource: "MenuBarIcon") ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
    }

    // MARK: menu lifecycle — meters animate only while the menu is open

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = readLevels()  // discard what accumulated while closed
        meterTimer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            meters.levels = readLevels()
        }
        RunLoop.main.add(meterTimer!, forMode: .common)  // .common so it ticks while the menu tracks
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        meterTimer?.invalidate()
        meterTimer = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let current = currentMic()
        let mics = AudioDevice.all().filter { $0.inputChannels > 0 && !Brand.isOwnDevice(name: $0.name, uid: $0.uid) }
        for mic in mics {
            let entry = NSMenuItem(title: mic.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mic.uid
            entry.state = mic.uid == current ? .on : .off
            menu.addItem(entry)
        }
    }

    // MARK: actions

    @objc private func selectMic(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String,
              let mic = AudioDevice.all().first(where: { $0.uid == uid }) else { return }
        onSelectMic(mic)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.write("launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func about() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 2
        func line(_ text: String, size: CGFloat, color: NSColor, link: String? = nil) -> NSAttributedString {
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size),
                                                             .foregroundColor: color, .paragraphStyle: centered]
            if let link { attributes[.link] = URL(string: link) }
            return NSAttributedString(string: text + "\n", attributes: attributes)
        }
        // one short line each, so nothing wraps mid-phrase in the narrow About panel
        let credits = NSMutableAttributedString()
        credits.append(line("Removes game audio from your mic, live.", size: 12, color: .labelColor))
        credits.append(line("github.com/AndBobsYourUncle", size: 12, color: .linkColor,
                            link: "https://github.com/AndBobsYourUncle"))
        credits.append(line("", size: 6, color: .labelColor))
        credits.append(line("Echo removal: DTLN-aec (MIT)", size: 10, color: .secondaryLabelColor))
        credits.append(line("and WebRTC AEC3 (BSD)", size: 10, color: .secondaryLabelColor))
        credits.append(line("Virtual devices: BlackHole source (GPL-3.0)", size: 10, color: .secondaryLabelColor))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: Brand.name, .applicationVersion: Brand.version, .version: "", .credits: credits,
        ])
    }

    @objc private func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Log.path)) }
    @objc private func quit() { onQuit() }
}

// MARK: - views

private let brandColors = [NSColor(srgbRed: 0.17, green: 0.89, blue: 1, alpha: 1),
                           NSColor(srgbRed: 0.61, green: 0.36, blue: 1, alpha: 1),
                           NSColor(srgbRed: 1, green: 0.31, blue: 0.85, alpha: 1)]

/// App icon, name and a status line with a coloured dot.
final class HeaderView: NSView {
    var status = "Starting…" { didSet { needsDisplay = true } }
    var healthy = true { didSet { needsDisplay = true } }

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: NSRect(x: 14, y: 8, width: 36, height: 36))
        (Brand.name as NSString).draw(at: NSPoint(x: 58, y: 26), withAttributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor])
        let dot = NSRect(x: 59, y: 12, width: 7, height: 7)
        (healthy ? NSColor.systemGreen : NSColor.systemOrange).setFill()
        NSBezierPath(ovalIn: dot).fill()
        (status as NSString).draw(at: NSPoint(x: 71, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

/// Three horizontal meters in the brand gradient, -60…0 dBFS.
final class MetersView: NSView {
    var levels = Levels() { didSet { needsDisplay = true } }
    private var held = Levels()  // smoothed, so bars fall gracefully

    init() { super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 74)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        func smooth(_ old: Float, _ new: Float) -> Float { new > old ? new : max(new, old - 2.5) }
        held.mic = smooth(held.mic, levels.mic)
        held.game = smooth(held.game, levels.game)
        held.out = smooth(held.out, levels.out)
        let rows: [(String, Float)] = [("Mic in", held.mic), ("Game", held.game), ("Voice out", held.out)]
        let gradient = NSGradient(colors: brandColors)!
        for (i, (label, db)) in rows.enumerated() {
            let y = CGFloat(52 - i * 22)
            (label as NSString).draw(at: NSPoint(x: 14, y: y + 1), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            let track = NSRect(x: 82, y: y + 4, width: 160, height: 7)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
            let fraction = CGFloat(max(0, min(1, (db + 60) / 60)))
            if fraction > 0.01 {
                let bar = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: bar, xRadius: 3.5, yRadius: 3.5).addClip()
                gradient.draw(in: track, angle: 0)  // gradient spans the track, revealed by the bar
                NSGraphicsContext.restoreGraphicsState()
            }
            let text = db <= -119 ? "—" : String(format: "%.0f dB", db)
            (text as NSString).draw(at: NSPoint(x: 250, y: y + 1), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

/// Arguments to use when launched without any (Finder, Dock, Login Items): one option per line in
/// the config file, created with the standard setup on first launch.
enum LaunchConfig {
    static let path = Brand.configPath
    static let standard = ["--output", Brand.micDevice, "--desktop-output", Brand.desktopDevice]
    private static let header = "# \(Brand.name) options used when launched from Finder/Dock/Login Items, one per line\n"

    /// Set (or replace) one option in the config file, e.g. setOption("--mic", "Wireless microphone").
    static func setOption(_ option: String, _ value: String) {
        var lines = arguments()
        if let i = lines.firstIndex(of: option), i + 1 < lines.count {
            lines[i + 1] = value
        } else {
            lines += [option, value]
        }
        write(lines)
    }

    static func arguments() -> [String] {
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            var lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            // switch configs from the BlackHole days to Unbleed's own devices once they're installed
            let names = Set(AudioDevice.all().map(\.name))
            if names.contains(Brand.micDevice), names.contains(Brand.desktopDevice),
               lines.contains(where: { $0.hasPrefix("BlackHole") }) {
                lines = lines.map { $0 == "BlackHole 2ch" ? Brand.micDevice : $0 == "BlackHole 16ch" ? Brand.desktopDevice : $0 }
                write(lines)
            }
            return lines
        }
        write(standard)
        return standard
    }

    private static func write(_ lines: [String]) {
        try? FileManager.default.createDirectory(atPath: Brand.supportDir, withIntermediateDirectories: true)
        try? (header + lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
