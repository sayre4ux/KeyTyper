// TypeThru: clipboard typing through a virtual HID keyboard or Quartz events.

import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Key map

struct KeyStroke {
    let keyCode: CGKeyCode
    let shift: Bool
}

/// Builds a character -> key press table from the active keyboard layout.
func buildKeyMap() -> [Character: KeyStroke] {
    var map: [Character: KeyStroke] = [:]
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        return map
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

    // Keypad keys depend on Num Lock on the remote side, so use the main keys only.
    let keypad: Set<CGKeyCode> = [65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
    let shiftState = UInt32((shiftKey >> 8) & 0xFF)

    layoutData.withUnsafeBytes { buffer in
        let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress!
        // Unshifted pass first, so "8" maps to the 8 key rather than a shifted one.
        for shift in [false, true] {
            for code in CGKeyCode(0)..<128 where !keypad.contains(code) {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), shift ? shiftState : 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
                guard status == noErr, length == 1, chars[0] >= 0x20, chars[0] != 0x7F,
                      let scalar = Unicode.Scalar(chars[0]) else { continue }
                let ch = Character(scalar)
                if map[ch] == nil { map[ch] = KeyStroke(keyCode: code, shift: shift) }
            }
        }
    }
    map["\n"] = KeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false)
    map["\r\n"] = KeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false)
    map["\r"] = KeyStroke(keyCode: CGKeyCode(kVK_Return), shift: false)
    map["\t"] = KeyStroke(keyCode: CGKeyCode(kVK_Tab), shift: false)
    return map
}

// MARK: - Typing

enum TypeResult {
    case done
    case cancelled(typed: Int, total: Int, reason: String)
}

enum TypingMethod: String, CaseIterable {
    case virtualKeyboard, hid, session, direct, unicode

    var title: String {
        switch self {
        case .virtualKeyboard: return "Virtual Keyboard"
        case .hid: return "HID key events"
        case .session: return "Session key events"
        case .direct: return "Direct to target app"
        case .unicode: return "Unicode text events"
        }
    }

    var shortTitle: String {
        self == .virtualKeyboard ? "Virtual Keyboard (recommended)" : "Quartz: \(title)"
    }

    func deliver(_ event: CGEvent, to pid: pid_t) {
        switch self {
        case .virtualKeyboard: preconditionFailure("Virtual keyboard uses HID reports, not Quartz")
        case .hid: event.post(tap: .cghidEventTap)
        case .session, .unicode: event.post(tap: .cgSessionEventTap)
        case .direct: event.postToPid(pid)
        }
    }
}

/// Built-in samples for checking a method, speed, and layout against the remote session.
enum TypingTest: CaseIterable {
    case short, capitals, symbols, smartSymbols, long

    var title: String {
        switch self {
        case .short: return "Short"
        case .capitals: return "Capitals"
        case .symbols: return "Symbols"
        case .smartSymbols: return "Smart symbols"
        case .long: return "Long"
        }
    }

    var text: String {
        switch self {
        case .short: return "abc123"
        case .capitals: return "AbC123!"
        case .symbols: return "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
        case .smartSymbols: return "• Bullet – en — em “double” ‘single’ … 3×4÷2 → ≤ ≥ ≠ © ® ™"
        case .long:
            return "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs!\n"
                + "Invoice #2048: $1,299.50 (incl. 8% tax) due 2026-10-31; ref A-17/B.\n"
                + "\tIndented: test@example.com, C:\\Temp\\notes.txt, {braces} [brackets] <angles>.\n"
                + "Sphinx of black quartz, judge my vow? 0123456789 ~ ` ^ | _ + = \" '"
        }
    }

    var help: String {
        switch self {
        case .short: return "Types abc123 at the slowest speed."
        case .capitals: return "Types AbC123! at the slowest speed, to check Shift."
        case .symbols: return "Types all 32 keyboard symbols at the slowest speed."
        case .smartSymbols: return "Types bullets, smart quotes, and dashes as plain keys: - Bullet - en -- em \"double\" 'single' ... 3x4/2 -> <= >= != (c) (R) (TM)"
        case .long: return "Types four lines with Tab and Return at your selected speed. Use a multi-line text field."
        }
    }

    // DECISION: short tests use the slowest speed to isolate the method; the long test checks the selected speed.
    var usesSelectedSpeed: Bool { self == .long }
}

/// Stops typing when the user acts: Esc, a mouse click, or a different app or window in front.
/// It polls key and button state on its own thread, so a quick tap is noticed even while a key
/// is held. It does not see which keys were typed or where the mouse was clicked.
final class StopWatcher {
    private let lock = NSLock()
    private var reason: String?
    private var finished = false

    var stopReason: String? { lock.lock(); defer { lock.unlock() }; return reason }

    init(target: pid_t) {
        let app = AXUIElementCreateApplication(target)
        let window = StopWatcher.focusedWindow(of: app)
        let buttons: [CGMouseButton] = [.left, .right, .center]
        // Buttons already down when typing starts (finishing a click on the target field) do not count.
        var wasDown = buttons.map { CGEventSource.buttonState(.hidSystemState, button: $0) }
        Thread.detachNewThread { [self] in
            var tick = 0
            while !isFinished {
                var found: String?
                if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Escape)) { found = "Esc pressed" }
                let down = buttons.map { CGEventSource.buttonState(.hidSystemState, button: $0) }
                if zip(down, wasDown).contains(where: { $0 && !$1 }) { found = "the mouse was clicked" }
                wasDown = down
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != target { found = "the front app changed" }
                // Accessibility queries are slower, so check the window every 50 ms.
                if tick % 5 == 0, let window, !StopWatcher.same(window, StopWatcher.focusedWindow(of: app)) {
                    found = "the front window changed"
                }
                if let found { stop(found); return }
                tick += 1
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    private func stop(_ why: String) { lock.lock(); if reason == nil { reason = why }; lock.unlock() }

    func finish() { lock.lock(); finished = true; lock.unlock() }

    private static func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func same(_ a: AXUIElement, _ b: AXUIElement?) -> Bool { b.map { CFEqual(a, $0) } ?? false }
}

final class Typer {
    // Keep the source identical across modes to isolate the delivery route.
    private let source = CGEventSource(stateID: .hidSystemState)
    private let keyboardType = Int64(LMGetKbdType())

    // Symbols with no key on common layouts, typed as plain keys that read the same.
    // DECISION: letters (such as é) are not replaced, because dropping an accent changes a word.
    static let replacements: [Character: String] = [
        "•": "-", "◦": "-", "▪": "-", "▫": "-", "‣": "-", "⁃": "-", "●": "-", "○": "-", "■": "-", "□": "-",
        "·": "-", "∙": "-", "‐": "-", "‑": "-", "‒": "-", "–": "-", "−": "-", "—": "--", "―": "--",
        "‘": "'", "’": "'", "‚": "'", "′": "'", "“": "\"", "”": "\"", "„": "\"", "″": "\"", "«": "\"", "»": "\"",
        "…": "...", "×": "x", "÷": "/", "→": "->", "←": "<-", "⇒": "=>", "≤": "<=", "≥": ">=", "≠": "!=",
        "©": "(c)", "®": "(R)", "™": "(TM)",
        "\u{00A0}": " ", "\u{2002}": " ", "\u{2003}": " ", "\u{2009}": " ", "\u{202F}": " ",
        "\u{200B}": "", "\u{FEFF}": "",
        // Line and paragraph separators, and Word's manual line break, become a normal line break.
        "\u{2028}": "\n", "\u{2029}": "\n", "\u{000B}": "\n", "\u{0085}": "\n",
    ]

    func typeable(_ ch: Character, map: [Character: KeyStroke], method: TypingMethod) -> Bool {
        switch method {
        case .unicode: return ch.utf16.count <= 20
        case .virtualKeyboard: return map[ch].flatMap { VirtualKeyboard.usages[$0.keyCode] } != nil
        default: return map[ch] != nil
        }
    }

    /// Replaces symbols that have no key, when every replacement character has one.
    func replacingUntypable(in text: String, map: [Character: KeyStroke],
                            method: TypingMethod) -> (text: String, replaced: Int) {
        var result = "", replaced = 0
        for ch in text {
            if !typeable(ch, map: map, method: method), let substitute = Typer.replacements[ch],
               substitute.allSatisfy({ typeable($0, map: map, method: method) }) {
                result += substitute
                replaced += 1
            } else {
                result.append(ch)
            }
        }
        return (result, replaced)
    }

    /// Returns the characters that cannot be typed, in order, without duplicates.
    func unsupported(in text: String, map: [Character: KeyStroke], method: TypingMethod = .hid) -> [Character] {
        var seen = Set<Character>()
        return text.filter { !typeable($0, map: map, method: method) && seen.insert($0).inserted }
    }

    /// Types at `interval` seconds per character (Shift adds a little more).
    func type(_ text: String, map: [Character: KeyStroke], interval: TimeInterval,
              method: TypingMethod, target: pid_t) -> TypeResult {
        let total = text.count
        let delay = Typer.delay(for: interval)
        let watcher = StopWatcher(target: target)
        defer { watcher.finish() }
        for (index, ch) in text.enumerated() {
            if let reason = watcher.stopReason { return .cancelled(typed: index, total: total, reason: reason) }
            if method == .virtualKeyboard {
                guard let stroke = map[ch], VirtualKeyboard.press(stroke, interval: interval) else {
                    return .cancelled(typed: index, total: total,
                                      reason: "Virtual Keyboard became unavailable; the last character may have been sent")
                }
                continue
            }
            // Construct a complete character before sending, so allocation failure cannot
            // leave a modifier held. Finish its key-up events before checking cancellation.
            guard let events = events(for: ch, map: map, method: method, delay: delay) else {
                return .cancelled(typed: index, total: total, reason: "a keyboard event could not be created")
            }
            for (event, wait) in events {
                method.deliver(event, to: target)
                pause(wait)
            }
        }
        return .done
    }

    /// Quartz events hold each key for 10 ms, so the rest of the interval follows the key-up.
    static func delay(for interval: TimeInterval) -> TimeInterval { max(0, interval - 0.01) }

    /// Line breaks as Shift+Return, for apps where Return sends or submits.
    static func shiftReturn(_ map: [Character: KeyStroke]) -> [Character: KeyStroke] {
        var map = map
        for ch: Character in ["\n", "\r", "\r\n"] { map[ch] = KeyStroke(keyCode: CGKeyCode(kVK_Return), shift: true) }
        return map
    }

    // Pure Quartz event construction: exercised by test.sh without posting keys.
    func events(for ch: Character, map: [Character: KeyStroke], method: TypingMethod,
                delay: TimeInterval) -> [(CGEvent, TimeInterval)]? {
        if method == .unicode && ![Character("\n"), "\r", "\r\n", "\t"].contains(ch) {
            let units = Array(String(ch).utf16)
            guard units.count <= 20,
                  let down = makeEvent(0, down: true, shift: false),
                  let up = makeEvent(0, down: false, shift: false) else { return nil }
            units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            return [(down, 0.01), (up, delay)]
        }
        // Return and Tab remain physical keys even in Unicode mode.
        let controls: [Character: CGKeyCode] = ["\n": 36, "\r": 36, "\r\n": 36, "\t": 48]
        guard let stroke = map[ch] ?? controls[ch].map({ KeyStroke(keyCode: $0, shift: false) }),
              let down = makeEvent(stroke.keyCode, down: true, shift: stroke.shift),
              let up = makeEvent(stroke.keyCode, down: false, shift: stroke.shift) else { return nil }
        if stroke.shift {
            guard let shiftDown = makeEvent(CGKeyCode(kVK_Shift), down: true, shift: true),
                  let shiftUp = makeEvent(CGKeyCode(kVK_Shift), down: false, shift: false) else { return nil }
            return [(shiftDown, delay / 2), (down, 0.01), (up, delay / 2), (shiftUp, delay)]
        }
        return [(down, 0.01), (up, delay)]
    }

    private func makeEvent(_ code: CGKeyCode, down: Bool, shift: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
        // A real keyboard reports Shift as a modifier change, not as a key down/up.
        if code == CGKeyCode(kVK_Shift) { event.type = .flagsChanged }
        event.flags = shift ? .maskShift : []
        // Remote clients use the keyboard type (ANSI/ISO/JIS) to turn key codes into scan codes.
        event.setIntegerValueField(.keyboardEventKeyboardType, value: keyboardType)
        return event
    }

    private func pause(_ seconds: TimeInterval) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }
}

/// Waits until Control, Option, Command and Shift are all released (up to `timeout`).
func waitForModifierRelease(timeout: TimeInterval = 3, includeTriggerKey: Bool = false) -> Bool {
    let held: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let modifiersUp = CGEventSource.flagsState(.hidSystemState).intersection(held).isEmpty
        let triggerUp = !includeTriggerKey || !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(currentShortcut.keyCode))
        if modifiersUp && triggerUp { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}

// MARK: - Global hotkey

/// A global shortcut: a macOS key code and Carbon modifier flags.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    // DECISION: Control+Backslash by default. The hotkey consumes its key but not its modifiers,
    // which still reach the remote session: on Windows a lone Alt opens the menu bar, and Command
    // may map to the Windows key. Control alone is harmless there, and Windows apps rarely use Ctrl+\.
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(controlKey))

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    static func load() -> Shortcut {
        let defaults = UserDefaults.standard
        guard let key = defaults.object(forKey: "shortcutKey") as? Int,
              let modifiers = defaults.object(forKey: "shortcutModifiers") as? Int else { return .standard }
        let shortcut = Shortcut(keyCode: UInt32(key), modifiers: UInt32(modifiers))
        return shortcut.problem == nil ? shortcut : .standard
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: "shortcutKey")
        UserDefaults.standard.set(Int(modifiers), forKey: "shortcutModifiers")
    }

    private func has(_ flag: Int) -> Bool { modifiers & UInt32(flag) != 0 }

    var isFunctionKey: Bool { Shortcut.functionKeys[Int(keyCode)] != nil }

    /// Why this cannot be the shortcut, or nil when it can.
    var problem: String? {
        if Int(keyCode) == kVK_Escape { return "Esc stops typing, so it cannot start it." }
        if !isFunctionKey && !has(controlKey) && !has(optionKey) && !has(cmdKey) {
            return "Add Control, Option, or Command, or use a function key such as F13."
        }
        return nil
    }

    /// A warning for shortcuts that work but may misbehave in a remote session.
    var caution: String? {
        guard has(optionKey) || has(cmdKey) || has(shiftKey) else { return nil }
        return "Option, Command, and Shift also reach the remote session and can trigger Windows shortcuts. Control alone is safest."
    }

    var title: String {
        var text = ""
        if has(controlKey) { text += "⌃" }
        if has(optionKey) { text += "⌥" }
        if has(shiftKey) { text += "⇧" }
        if has(cmdKey) { text += "⌘" }
        return text + keyName
    }

    /// The key's label on the current layout, so ⌃\ reads correctly on non-US keyboards too.
    var keyName: String {
        if let name = Shortcut.functionKeys[Int(keyCode)] ?? Shortcut.namedKeys[Int(keyCode)] { return name }
        let character = buildKeyMap().first { $0.value.keyCode == CGKeyCode(keyCode) && !$0.value.shift }?.key
        return character.map { String($0).uppercased() } ?? "Key \(keyCode)"
    }
}

var currentShortcut = Shortcut.standard
var onHotKey: (() -> Void)?
var hotKeyRef: EventHotKeyRef?
var hotKeyHandlerInstalled = false
var hotKeyRegistrationStatus: OSStatus = OSStatus(eventNotHandledErr)
var lastHotKeyReceived: Date?

/// Registers `shortcut` as the global hotkey, replacing the current one. Returns false if
/// macOS refuses it; then nothing is registered.
func registerHotKey(_ shortcut: Shortcut) -> Bool {
    if !hotKeyHandlerInstalled {
        // Start on release, so the remote client has a chance to receive the physical key-up
        // sequence before the virtual keyboard begins a new sequence.
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            lastHotKeyReceived = Date()
            onHotKey?()
            return noErr
        }, 1, &spec, nil, nil)
        guard handlerStatus == noErr else {
            hotKeyRegistrationStatus = handlerStatus
            return false
        }
        hotKeyHandlerInstalled = true
    }
    unregisterHotKey()
    let id = EventHotKeyID(signature: OSType(0x4B545950), id: 1) // "KTYP"
    hotKeyRegistrationStatus = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    if hotKeyRegistrationStatus == noErr { currentShortcut = shortcut }
    return hotKeyRegistrationStatus == noErr
}

func unregisterHotKey() {
    if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
    hotKeyRef = nil
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let typer = Typer()
    private var busy = false
    private var lastAttempt = "No attempt in this session."
    private var method: TypingMethod {
        get { TypingMethod(rawValue: UserDefaults.standard.string(forKey: "typingMethodV2") ?? "") ?? .virtualKeyboard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "typingMethodV2") }
    }
    private let panel = PanelController()
    private let settingsWindow = SettingsWindowController()
    private var updateTimer: Timer?
    private var shortcutRecorder: Any?
    private var panelClosedAt = Date.distantPast
    // DECISION: time per character at 5 characters per word. A study of 168,000 typists
    // averaged 52 WPM and its fastest reached about 120; sprint records are 200 to 300 WPM.
    private let speeds: [(title: String, interval: TimeInterval, detail: String)] = [
        ("Average typist · 50 WPM", 0.24, "240 ms per key. A typical typist, and the most reliable."),
        ("Fast typist · 100 WPM", 0.12, "120 ms per key. The fastest 5% of typists."),
        ("Record typist · 200 WPM", 0.06, "60 ms per key. World-record pace."),
        ("Superhuman · 400 WPM", 0.03, "30 ms per key. Some remote sessions drop keys."),
        ("Unrealistic · 600 WPM", 0.02, "20 ms per key. Expect dropped keys on slow connections."),
    ]
    private var interval: TimeInterval {
        get { UserDefaults.standard.object(forKey: "typingInterval") as? TimeInterval ?? 0.24 }
        set { UserDefaults.standard.set(newValue, forKey: "typingInterval") }
    }
    private var replaceSymbols: Bool {
        get { UserDefaults.standard.object(forKey: "replaceSymbols") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "replaceSymbols") }
    }
    // DECISION: on by default (user request): Shift+Return makes a new line in chat apps and word
    // processors instead of sending. Spreadsheets move up a cell, so the panel can turn it off.
    private var checkUpdates: Bool {
        get { UserDefaults.standard.object(forKey: "checkUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkUpdates") }
    }
    private var shiftReturn: Bool {
        get { UserDefaults.standard.object(forKey: "shiftReturn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "shiftReturn") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // DECISION: one dark look everywhere, alerts included, to match the panel and icon.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Brand.menuBarImage()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        setUpPanel()
        if requireApplicationsFolder() { return }
        migrateFromKeyTyper()

        onHotKey = { [weak self] in self?.trigger(fromMenu: false) }
        let shortcut = Shortcut.load()
        if !registerHotKey(shortcut) {
            alert("Could not use \(shortcut.title)", "macOS returned error \(hotKeyRegistrationStatus). Another app may use this shortcut. Choose a different one in TypeThru Settings.")
        }
        if !AXIsProcessTrusted() { promptForAccessibility() }
        continueOnboarding()
        scheduleUpdateChecks()
    }

    /// An app opened from the disk image, or one macOS moved to a temporary copy, loses its
    /// Accessibility permission later. Ask the user to move it first. Returns true when quitting.
    private func requireApplicationsFolder() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return false }
        alert("Move TypeThru to Applications",
              "Drag TypeThru into the Applications folder, eject the TypeThru disk, then open TypeThru from Applications.")
        NSApp.terminate(nil)
        return true
    }

    /// Builds before 0.3 were called KeyTyper. Move their settings once, then remove the old
    /// settings and Accessibility entry. The old helper is replaced the next time setup runs.
    private func migrateFromKeyTyper() {
        let defaults = UserDefaults.standard
        let old = "local.keytyper"
        guard !defaults.bool(forKey: "migratedFromKeyTyper") else { return }
        defaults.set(true, forKey: "migratedFromKeyTyper")
        guard let settings = UserDefaults.standard.persistentDomain(forName: old) else { return }
        // DECISION: the onboarding flag is not copied, so the new helper's setup is offered again.
        for key in ["typingMethodV2", "typingInterval", "replaceSymbols", "shiftReturn"] {
            if let value = settings[key] { defaults.set(value, forKey: key) }
        }
        defaults.removePersistentDomain(forName: old)
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", old]
        try? reset.run()
    }

    /// First run: Accessibility first, then Virtual Keyboard setup, so the two prompts never overlap.
    private func continueOnboarding() {
        let key = "virtualKeyboardOnboardingShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.continueOnboarding() }
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.global(qos: .userInitiated).async {
            let status = VirtualKeyboard.status()
            DispatchQueue.main.async { if status != .ready { self.setupVirtualKeyboard() } }
        }
    }

    private func setUpPanel() {
        let model = panel.model
        model.speeds = speeds.map(\.title)
        model.speedDetails = speeds.map(\.detail)
        model.onChange = { [weak self] in
            guard let self else { return }
            let methodChanged = self.method != model.method
            self.method = model.method
            self.interval = self.speeds[model.speedIndex].interval
            self.replaceSymbols = model.replaceSymbols
            self.shiftReturn = model.shiftReturn
            if model.checkUpdates != self.checkUpdates {
                self.checkUpdates = model.checkUpdates
                if model.checkUpdates { self.checkForUpdates(manual: false) }
            }
            if model.launchAtLogin != (SMAppService.mainApp.status == .enabled) { self.setLaunchAtLogin(model.launchAtLogin) }
            if methodChanged { self.refreshStatus() }
        }
        model.perform = { [weak self] action in self?.perform(action) }
        settingsWindow.onClose = { [weak self] in
            if self?.shortcutRecorder != nil { self?.finishRecording(nil) }
        }
        syncModel()
    }

    /// Copies saved settings into the model the panel and Settings window show.
    private func syncModel() {
        let model = panel.model
        model.method = method
        model.speedIndex = speeds.firstIndex { abs($0.interval - interval) < 0.0001 } ?? 0
        model.replaceSymbols = replaceSymbols
        model.shiftReturn = shiftReturn
        model.checkUpdates = checkUpdates
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        model.busy = busy
        model.shortcut = currentShortcut.title
        model.shortcutIsStandard = currentShortcut == .standard
    }

    private func openSettings() {
        syncModel()
        panel.model.shortcutNote = nil
        panel.model.launchNote = SMAppService.mainApp.status == .requiresApproval
            ? "Allow TypeThru in System Settings › General › Login Items." : nil
        settingsWindow.show(model: panel.model)
        refreshStatus()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            panel.model.launchNote = SMAppService.mainApp.status == .requiresApproval
                ? "Allow TypeThru in System Settings › General › Login Items." : nil
        } catch {
            panel.model.launchNote = "macOS did not allow this: \(error.localizedDescription)"
        }
        panel.model.launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Updates

    /// Checks at launch and then hourly, but asks GitHub at most once a day.
    private func scheduleUpdateChecks() {
        if let version = UserDefaults.standard.string(forKey: "availableVersion"),
           let link = UserDefaults.standard.string(forKey: "availablePage"), let page = URL(string: link),
           Updates.isReleasePage(page), Updates.isNewer(version, than: Updates.currentVersion) {
            panel.model.update = Updates.Release(version: version, page: page)
            panel.model.updateStatus = "Version \(version) is available."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkForUpdates(manual: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(manual: false)
        }
    }

    private func checkForUpdates(manual: Bool) {
        let defaults = UserDefaults.standard
        if !manual {
            guard checkUpdates else { return }
            if let last = defaults.object(forKey: "lastUpdateCheck") as? Date, Date().timeIntervalSince(last) < 20 * 3600 { return }
        }
        panel.model.updateStatus = "Checking…"
        Updates.check { [weak self] result in
            guard let model = self?.panel.model else { return }
            switch result {
            case .success(let release):
                defaults.set(Date(), forKey: "lastUpdateCheck")
                defaults.set(release?.version, forKey: "availableVersion")
                defaults.set(release?.page.absoluteString, forKey: "availablePage")
                model.update = release
                model.updateStatus = release.map { "Version \($0.version) is available." } ?? "TypeThru is up to date."
            case .failure:
                model.updateStatus = "Could not reach GitHub. Try again later."
            }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        // A click on the menu bar icon first closes the open panel; do not reopen it.
        if panel.isShown || Date().timeIntervalSince(panelClosedAt) < 0.3 { panel.close(); return }
        syncModel()
        panel.onClose = { [weak self] in self?.panelClosedAt = Date() }
        panel.show(below: button)
        refreshStatus()
    }

    private func refreshStatus() {
        let method = self.method
        DispatchQueue.global(qos: .userInitiated).async {
            let trusted = AXIsProcessTrusted()
            let keyboard = method == .virtualKeyboard ? VirtualKeyboard.status() : .ready
            let status: PanelModel.Status
            if !trusted { status = .init(text: "Allow Accessibility", ready: false) }
            else if keyboard == .notInstalled { status = .init(text: "Set up needed", ready: false, needsSetUp: true) }
            else if keyboard != .ready { status = .init(text: "Not ready", ready: false) }
            else { status = .init(text: "Ready", ready: true) }
            DispatchQueue.main.async { self.panel.model.status = status }
        }
    }

    /// Records the next key press in Settings as the shortcut. Only TypeThru's own window sees it;
    /// the hotkey is off meanwhile, so pressing the old shortcut does not start typing.
    private func startRecording() {
        unregisterHotKey()
        panel.model.recording = true
        panel.model.shortcutNote = "Press the new shortcut. Esc cancels."
        shortcutRecorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if Int(event.keyCode) == kVK_Escape && held.isEmpty { finishRecording(nil); return }
        let shortcut = Shortcut(keyCode: event.keyCode, flags: held)
        if let problem = shortcut.problem { panel.model.shortcutNote = problem; return }
        finishRecording(shortcut)
    }

    private func finishRecording(_ shortcut: Shortcut?) {
        if let recorder = shortcutRecorder { NSEvent.removeMonitor(recorder) }
        shortcutRecorder = nil
        panel.model.recording = false
        if let shortcut { apply(shortcut) } else { _ = registerHotKey(currentShortcut); panel.model.shortcutNote = nil }
    }

    private func apply(_ shortcut: Shortcut) {
        let previous = currentShortcut
        if registerHotKey(shortcut) {
            shortcut.save()
            panel.model.shortcutNote = shortcut.caution
        } else {
            _ = registerHotKey(previous)
            panel.model.shortcutNote = "macOS did not accept \(shortcut.title). Another app may use it."
        }
        panel.model.shortcut = currentShortcut.title
        panel.model.shortcutIsStandard = currentShortcut == .standard
    }

    private func setBusy(_ value: Bool) {
        busy = value
        panel.model.busy = value
        statusItem.button?.title = value ? "…" : ""
    }

    private func perform(_ action: PanelAction) {
        panel.close()
        switch action {
        case .recordShortcut: if shortcutRecorder == nil { startRecording() } else { finishRecording(nil) }
        case .resetShortcut: apply(.standard)
        case .openSettings: openSettings()
        case .checkForUpdates: checkForUpdates(manual: true)
        case .openUpdate: if let page = panel.model.update?.page { NSWorkspace.shared.open(page) }
        case .typeClipboard: trigger(fromMenu: true)
        case .test(let test): trigger(fromMenu: true, test: test)
        case .setUp: setupVirtualKeyboard()
        case .checkVirtualKeyboard: checkVirtualKeyboard()
        case .checkAccessibility: checkPermission()
        case .diagnostics: showDiagnostics()
        case .uninstall: uninstall()
        case .quit: NSApp.terminate(nil)
        }
    }

    @objc private func setupVirtualKeyboard() {
        guard !busy else { NSSound.beep(); return }
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = "Set up TypeThru Virtual Keyboard"
        sheet.informativeText = "Virtual Keyboard types through a virtual USB keyboard, so VDI and remote desktop clients receive real key presses.\n\n1. Choose Set Up and enter your Mac administrator password. This installs a small background helper and the Karabiner virtual keyboard driver. An already installed driver is reused.\n2. If macOS asks, allow the Karabiner driver in System Settings.\n3. In the TypeThru panel, choose the Short typing test, then click a text field in your remote session.\n\nTypeThru itself stays unprivileged. A small helper runs in the background and accepts keyboard reports only from your Mac user account. TypeThru only sends key presses. It never reads what you type, and clipboard text is never written to files or logs. Keep the keyboard layout on this Mac and in the remote session the same.\n\nTo remove everything later, open Settings from the TypeThru panel and choose Uninstall TypeThru…."
        sheet.addButton(withTitle: "Set Up")
        sheet.addButton(withTitle: "Later")
        guard sheet.runModal() == .alertFirstButtonReturn else { return }
        let result = VirtualKeyboard.runAsAdministrator(
            "install-helper", files: ["TypeThru-VirtualKeyboard", "Karabiner-DriverKit-VirtualHIDDevice-8.6.0.pkg"],
            [String(getuid())],
            prompt: "TypeThru needs your password to install its Virtual Keyboard helper.")
        if case let .failed(reason) = result { alert("Setup did not finish", reason); return }
        guard result == .done else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            VirtualKeyboard.runManager("activate")
            // The helper connects to the driver within a few seconds of starting.
            var status = VirtualKeyboard.status()
            for _ in 0..<10 where status != .ready {
                Thread.sleep(forTimeInterval: 1)
                status = VirtualKeyboard.status()
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                if status == .driverNotReady { self.askToApproveDriver() } else { self.alert(status.title, status.help) }
            }
        }
    }

    private func askToApproveDriver() {
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = "Allow the Karabiner driver"
        sheet.informativeText = "The helper is installed. In System Settings, allow the Karabiner virtual keyboard driver (General > Login Items & Extensions > Driver Extensions, or Privacy & Security). Then choose Check under Virtual Keyboard in TypeThru Settings."
        sheet.addButton(withTitle: "Open System Settings")
        sheet.addButton(withTitle: "Later")
        guard sheet.runModal() == .alertFirstButtonReturn else { return }
        // DECISION: driver approval moved to Login Items & Extensions in macOS 15.
        let pane = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            ? "com.apple.LoginItems-Settings.extension" : "com.apple.preference.security"
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    @objc private func checkVirtualKeyboard() {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = VirtualKeyboard.status()
            DispatchQueue.main.async { self.alert(status.title, status.help) }
        }
    }

    @objc private func uninstall() {
        guard !busy else { NSSound.beep(); return }
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = "Uninstall TypeThru?"
        sheet.informativeText = "This removes the background helper, TypeThru's settings, and its Accessibility permission, then quits TypeThru. macOS asks for your administrator password."
        let driverInstalled = FileManager.default.fileExists(atPath: VirtualKeyboard.driverDirectory)
        if driverInstalled {
            sheet.showsSuppressionButton = true
            sheet.suppressionButton?.title = "Also remove the Karabiner virtual keyboard driver"
            sheet.suppressionButton?.state = .off
            if FileManager.default.fileExists(atPath: "/Applications/Karabiner-Elements.app") {
                sheet.informativeText += "\n\nKarabiner-Elements uses the same driver. Keep the driver unless you are also removing Karabiner-Elements."
            }
        }
        sheet.addButton(withTitle: "Uninstall")
        sheet.addButton(withTitle: "Cancel")
        guard sheet.runModal() == .alertFirstButtonReturn else { return }
        let removeDriver = driverInstalled && sheet.suppressionButton?.state == .on
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            // The driver is deactivated as the user before root removes its files.
            if removeDriver { VirtualKeyboard.runManager("deactivate") }
            DispatchQueue.main.async { self.finishUninstall(removeDriver: removeDriver) }
        }
    }

    private func finishUninstall(removeDriver: Bool) {
        let result = VirtualKeyboard.runAsAdministrator(
            "uninstall-helper", [removeDriver ? "remove-driver" : "keep-driver"],
            prompt: "TypeThru needs your password to remove its Virtual Keyboard helper.")
        setBusy(false)
        if case let .failed(reason) = result { alert("Uninstall did not finish", reason); return }
        guard result == .done else { return }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "io.github.sayre4ux.typethru")
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "io.github.sayre4ux.typethru"]
        var resetDone = false
        if (try? reset.run()) != nil { reset.waitUntilExit(); resetDone = reset.terminationStatus == 0 }
        alert("TypeThru is uninstalled", "Move TypeThru from Applications to the Trash to finish."
              + (resetDone ? "" : " Also remove TypeThru from System Settings > Privacy & Security > Accessibility.")
              + (removeDriver ? " Restart your Mac if the driver still appears in System Settings." : ""))
        NSApp.terminate(nil)
    }

    @objc private func showDiagnostics() {
        let lastShortcut = lastHotKeyReceived.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "Never received in this session"
        alert("TypeThru Diagnostics", "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")\nShortcut: \(currentShortcut.title), \(hotKeyRegistrationStatus == noErr ? "registered" : "error \(hotKeyRegistrationStatus)")\nLast shortcut received: \(lastShortcut)\nSecure Event Input: \(IsSecureEventInputEnabled() ? "enabled" : "disabled")\nSelected: \(method.title)\n\n\(lastAttempt)\n\nSent events do not confirm that the remote session accepted them. Clipboard contents are not recorded. Secure Event Input is sampled on this Mac, not inside the remote session.")
    }

    @objc private func checkPermission() {
        if AXIsProcessTrusted() {
            alert("Permission granted", "TypeThru can send key presses.")
        } else {
            promptForAccessibility()
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func trigger(fromMenu: Bool, test: TypingTest? = nil) {
        let testText = test?.text
        guard !busy else { NSSound.beep(); return }
        let method = self.method
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lastAttempt = "Attempt: \(time)\nTrigger: \(test.map { "\($0.title) test" } ?? (fromMenu ? "panel" : "shortcut"))\nMethod: \(method.title)\nSecure Event Input at trigger: \(IsSecureEventInputEnabled() ? "enabled" : "disabled")"
        guard AXIsProcessTrusted() else {
            lastAttempt += "\nNot started: Accessibility permission missing."
            promptForAccessibility(); return
        }
        guard let original = testText ?? NSPasteboard.general.string(forType: .string), !original.isEmpty else {
            lastAttempt += "\nNot started: clipboard has no text."
            alert("Nothing typed", "The clipboard has no text. You can try a typing test from the TypeThru panel.")
            return
        }
        let map = shiftReturn ? Typer.shiftReturn(buildKeyMap()) : buildKeyMap()
        if shiftReturn { lastAttempt += "\nLine breaks: Shift+Return." }
        // The smart symbols test exists to show the replacements, so it always replaces.
        let (text, replaced) = (replaceSymbols || test == .smartSymbols) && method != .unicode
            ? typer.replacingUntypable(in: original, map: map, method: method) : (original, 0)
        if replaced > 0 { lastAttempt += "\nReplaced \(replaced) symbols that have no key." }
        let missing = typer.unsupported(in: text, map: map, method: method)
        if !missing.isEmpty {
            lastAttempt += "\nNot started: unsupported characters."
            alert("Nothing typed", method == .unicode
                  ? "The text contains a character too long for a Unicode keyboard event."
                  : "Some characters have no key on the current keyboard layout. Try Unicode text events, or check your keyboard layout.")
            return
        }

        setBusy(true)
        let interval = test.map { $0.usesSelectedSpeed ? self.interval : speeds[0].interval } ?? self.interval
        let shortcutTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lastAttempt += "\nSpeed: \(Int(interval * 1000)) ms per character\nWaiting to start."
        DispatchQueue.global(qos: .userInitiated).async { [typer] in
            let status = method == .virtualKeyboard ? VirtualKeyboard.status() : .ready
            if status != .ready {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.lastAttempt += "\nNot started: \(status.title)."
                    if status == .notInstalled { self.setupVirtualKeyboard() }
                    else { self.alert("Nothing typed: \(status.title)", status.help) }
                }
                return
            }
            // Panel runs let the user explicitly focus the remote field. Shortcut runs
            // retain their original target rather than silently picking a different app.
            if fromMenu { Thread.sleep(forTimeInterval: testText == nil ? 1.0 : 3.0) }
            let released = waitForModifierRelease(includeTriggerKey: !fromMenu)
            if released { Thread.sleep(forTimeInterval: fromMenu ? 0.15 : 0.75) }
            var target: NSRunningApplication?
            DispatchQueue.main.sync { target = NSWorkspace.shared.frontmostApplication }
            let result: TypeResult
            if !released {
                result = .cancelled(typed: 0, total: text.count, reason: "shortcut or modifier keys were not released")
            } else if let target = target, target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      fromMenu || target.processIdentifier == shortcutTarget {
                result = typer.type(text, map: map, interval: interval, method: method, target: target.processIdentifier)
            } else {
                result = .cancelled(typed: 0, total: text.count, reason: "the target app was unavailable or changed before typing")
            }
            let targetName = target?.localizedName ?? "unknown"
            DispatchQueue.main.async {
                self.setBusy(false)
                self.lastAttempt += "\nTarget: \(targetName)"
                if case let .cancelled(typed, total, reason) = result {
                    self.lastAttempt += "\nStopped after sending \(typed) of \(total) characters: \(reason)."
                    NSSound.beep()
                    self.alert("Typing stopped", "Stopped after sending \(typed) of \(total) characters because \(reason).")
                } else {
                    self.lastAttempt += "\nSent events for \(text.count) characters. Remote acceptance is unverified."
                }
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - Entry point

if CommandLine.arguments.dropFirst().first == "--print-map" {
    // Shows which key presses a text would produce, without typing anything.
    let text = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    let map = buildKeyMap()
    for ch in text {
        if let s = map[ch] { print("\(ch.debugDescription)\tkey \(s.keyCode)\(s.shift ? " + Shift" : "")") }
        else if let r = Typer.replacements[ch], r.allSatisfy({ map[$0] != nil }) { print("\(ch.debugDescription)\treplaced with \(r.debugDescription)") }
        else { print("\(ch.debugDescription)\tNO KEY") }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
