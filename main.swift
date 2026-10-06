// KeyTyper: clipboard typing through a virtual HID keyboard or Quartz events.

import AppKit
import Carbon.HIToolbox

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

    var menuTitle: String {
        self == .virtualKeyboard ? "Virtual Keyboard: for VDI and remote desktops (recommended)" : title
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
        for (index, ch) in text.enumerated() {
            if CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Escape)) {
                return .cancelled(typed: index, total: total, reason: "Esc pressed")
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != target {
                return .cancelled(typed: index, total: total, reason: "the front app changed")
            }
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
        let triggerUp = !includeTriggerKey || !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(hotKeyCode))
        if modifiersUp && triggerUp { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return false
}

// MARK: - Global hotkey (Control+Backslash)

// DECISION: Control+Backslash. The hotkey consumes its key but not its modifiers, which still
// reach the remote session: on Windows a lone Alt opens the menu bar, and Command may map to the
// Windows key. Control alone is harmless there, and Windows apps rarely use Ctrl+\.
let hotKeyCode = UInt32(kVK_ANSI_Backslash)
let hotKeyModifiers = UInt32(controlKey)
var onHotKey: (() -> Void)?
var hotKeyRef: EventHotKeyRef?
var hotKeyRegistrationStatus: OSStatus = OSStatus(eventNotHandledErr)
var lastHotKeyReceived: Date?

func registerHotKey() -> Bool {
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
    let id = EventHotKeyID(signature: OSType(0x4B545950), id: 1) // "KTYP"
    hotKeyRegistrationStatus = RegisterEventHotKey(hotKeyCode, hotKeyModifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    return hotKeyRegistrationStatus == noErr
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
    // DECISION: time per character at 5 characters per word. A study of 168,000 typists
    // averaged 52 WPM and its fastest reached about 120; sprint records are 200 to 300 WPM.
    private let speeds: [(String, TimeInterval)] = [
        ("Average typist (50 WPM)", 0.24), ("Fast typist (100 WPM)", 0.12), ("Record typist (200 WPM)", 0.06),
        ("Superhuman (400 WPM)", 0.03), ("Unrealistic (600 WPM)", 0.02),
    ]
    private var interval: TimeInterval {
        get { UserDefaults.standard.object(forKey: "typingInterval") as? TimeInterval ?? 0.24 }
        set { UserDefaults.standard.set(newValue, forKey: "typingInterval") }
    }
    private var replaceSymbols: Bool {
        get { UserDefaults.standard.object(forKey: "replaceSymbols") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "replaceSymbols") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "KeyTyper")
        rebuildMenu()

        onHotKey = { [weak self] in self?.trigger(fromMenu: false) }
        if !registerHotKey() {
            alert("Could not register ⌃\\", "macOS returned error \(hotKeyRegistrationStatus). The shortcut may be in use by another app. Use the menu bar item instead.")
        }
        if !AXIsProcessTrusted() { promptForAccessibility() }
        continueOnboarding()
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

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Type Clipboard (⌃\\)", action: #selector(typeFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Test abc123 in 3 seconds", action: #selector(testTyping), keyEquivalent: "")
        menu.addItem(withTitle: "Test AbC123! in 3 seconds", action: #selector(testShiftTyping), keyEquivalent: "")
        menu.addItem(.separator())
        let methods = NSMenuItem(title: "Typing Method", action: nil, keyEquivalent: "")
        let methodMenu = NSMenu()
        for (index, value) in TypingMethod.allCases.enumerated() {
            if index == 1 {
                methodMenu.addItem(.separator())
                methodMenu.addItem(withTitle: "Quartz events: for apps on this Mac", action: nil, keyEquivalent: "")
            }
            let item = NSMenuItem(title: value.menuTitle, action: #selector(setMethod(_:)), keyEquivalent: "")
            item.tag = index
            item.state = value == method ? .on : .off
            item.indentationLevel = value == .virtualKeyboard ? 0 : 1
            item.target = self
            methodMenu.addItem(item)
        }
        methods.submenu = methodMenu
        menu.addItem(methods)
        let speed = NSMenuItem(title: "Typing Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for (index, (title, value)) in speeds.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.tag = index
            item.state = abs(value - interval) < 0.0001 ? .on : .off
            speedMenu.addItem(item)
        }
        speed.submenu = speedMenu
        menu.addItem(speed)
        let replace = menu.addItem(withTitle: "Replace Symbols Without a Key (• → -)", action: #selector(toggleReplaceSymbols), keyEquivalent: "")
        replace.state = replaceSymbols ? .on : .off
        menu.addItem(withTitle: "Set Up Virtual Keyboard…", action: #selector(setupVirtualKeyboard), keyEquivalent: "")
        menu.addItem(withTitle: "Check Virtual Keyboard", action: #selector(checkVirtualKeyboard), keyEquivalent: "")
        menu.addItem(withTitle: "Uninstall KeyTyper…", action: #selector(uninstall), keyEquivalent: "")
        menu.addItem(withTitle: "Check Accessibility Permission", action: #selector(checkPermission), keyEquivalent: "")
        menu.addItem(withTitle: "Last Attempt / Diagnostics", action: #selector(showDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Press Esc or switch apps to stop typing", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit KeyTyper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = item.action == #selector(NSApplication.terminate(_:)) ? NSApp : self }
        for item in speedMenu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        interval = speeds[sender.tag].1
        rebuildMenu()
    }

    @objc private func toggleReplaceSymbols() {
        replaceSymbols.toggle()
        rebuildMenu()
    }

    @objc private func typeFromMenu() { trigger(fromMenu: true) }

    @objc private func testTyping() { trigger(fromMenu: true, testText: "abc123") }
    @objc private func testShiftTyping() { trigger(fromMenu: true, testText: "AbC123!") }

    @objc private func setMethod(_ sender: NSMenuItem) {
        method = TypingMethod.allCases[sender.tag]
        rebuildMenu()
        if method == .virtualKeyboard { checkVirtualKeyboard() }
    }

    @objc private func setupVirtualKeyboard() {
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = "Set up KeyTyper Virtual Keyboard"
        sheet.informativeText = "Virtual Keyboard types through a virtual USB keyboard, so VDI and remote desktop clients receive real key presses.\n\n1. Run the one-time setup and enter your Mac administrator password in Terminal.\n2. Approve the Karabiner DriverKit system extension in System Settings if asked. An already approved driver is reused.\n3. Return here, choose Check Virtual Keyboard, then try Test abc123 in 3 seconds.\n\nKeyTyper itself stays unprivileged. A small helper runs in the background and accepts keyboard reports only from your Mac user account. KeyTyper only sends key presses. It never reads what you type, and clipboard text is never written to files or logs. Keep the keyboard layout on this Mac and in the remote session the same.\n\nTo remove everything later, choose Uninstall KeyTyper… from the KeyTyper menu."
        sheet.addButton(withTitle: "Run Setup")
        sheet.addButton(withTitle: "Later")
        if sheet.runModal() == .alertFirstButtonReturn,
           let url = Bundle.main.url(forResource: "Set Up Virtual Keyboard", withExtension: "command") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkVirtualKeyboard() {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = VirtualKeyboard.status()
            DispatchQueue.main.async { self.alert(status.title, status.help) }
        }
    }

    @objc private func uninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let sheet = NSAlert()
        sheet.messageText = "Uninstall KeyTyper?"
        sheet.informativeText = "Terminal will open, quit KeyTyper, and remove its background helper, settings, and Accessibility permission. It asks for your Mac administrator password, and asks before removing the Karabiner driver, which other apps may share. Delete KeyTyper.app afterwards."
        sheet.addButton(withTitle: "Uninstall")
        sheet.addButton(withTitle: "Cancel")
        if sheet.runModal() == .alertFirstButtonReturn,
           let url = Bundle.main.url(forResource: "Uninstall KeyTyper", withExtension: "command") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showDiagnostics() {
        let lastShortcut = lastHotKeyReceived.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? "Never received in this session"
        alert("KeyTyper Diagnostics", "Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")\nShortcut registration: \(hotKeyRegistrationStatus == noErr ? "OK" : "error \(hotKeyRegistrationStatus)")\nLast shortcut received: \(lastShortcut)\nSecure Event Input: \(IsSecureEventInputEnabled() ? "enabled" : "disabled")\nSelected: \(method.title)\n\n\(lastAttempt)\n\nSent events do not confirm that the remote session accepted them. Clipboard contents are not recorded. Secure Event Input is sampled on this Mac, not inside the remote session.")
    }

    @objc private func checkPermission() {
        if AXIsProcessTrusted() {
            alert("Permission granted", "KeyTyper can send key presses.")
        } else {
            promptForAccessibility()
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func trigger(fromMenu: Bool, testText: String? = nil) {
        guard !busy else { NSSound.beep(); return }
        let method = self.method
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        lastAttempt = "Attempt: \(time)\nTrigger: \(fromMenu ? "menu" : "shortcut")\nMethod: \(method.title)\nSecure Event Input at trigger: \(IsSecureEventInputEnabled() ? "enabled" : "disabled")"
        guard AXIsProcessTrusted() else {
            lastAttempt += "\nNot started: Accessibility permission missing."
            promptForAccessibility(); return
        }
        guard let original = testText ?? NSPasteboard.general.string(forType: .string), !original.isEmpty else {
            lastAttempt += "\nNot started: clipboard has no text."
            alert("Nothing typed", "The clipboard has no text. You can use the built-in test from the menu.")
            return
        }
        let map = buildKeyMap()
        let (text, replaced) = replaceSymbols && method != .unicode
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

        busy = true
        statusItem.button?.title = "…"
        // The test uses the slowest speed; changing the method is the only test variable.
        let interval = testText == nil ? self.interval : speeds[0].1
        let shortcutTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
        lastAttempt += "\nSpeed: \(Int(interval * 1000)) ms per character\nWaiting to start."
        DispatchQueue.global(qos: .userInitiated).async { [typer] in
            let status = method == .virtualKeyboard ? VirtualKeyboard.status() : .ready
            if status != .ready {
                DispatchQueue.main.async {
                    self.busy = false
                    self.statusItem.button?.title = ""
                    self.lastAttempt += "\nNot started: \(status.title)."
                    if status == .notInstalled { self.setupVirtualKeyboard() }
                    else { self.alert("Nothing typed: \(status.title)", status.help) }
                }
                return
            }
            // Menu tests let the user explicitly focus the remote field. Shortcut runs
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
                self.busy = false
                self.statusItem.button?.title = ""
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
