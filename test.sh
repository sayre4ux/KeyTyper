#!/bin/sh
# Exercise actual event construction without posting any input or reading the clipboard.
set -eu
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/typethru-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
cat VirtualKeyboard.swift Panel.swift Settings.swift Updates.swift Brand.swift > "$TEST_DIR/main.swift"
sed '/^\/\/ MARK: - Entry point/,$d' main.swift >> "$TEST_DIR/main.swift"
echo 'enum ResourceHashes { static let sha256: [String: String] = [:] }' >> "$TEST_DIR/main.swift"
cat >> "$TEST_DIR/main.swift" <<'SWIFT'

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
func section(_ name: String, _ body: () -> Void) {
    let before = checks
    body()
    print("ok  \(name) (\(checks - before) checks)")
}

let typer = Typer()
let quartz = TypingMethod.allCases.filter { $0 != .virtualKeyboard && $0 != .unicode }
let keyMethods = TypingMethod.allCases.filter { $0 != .unicode }
let fixture: [Character: KeyStroke] = [
    "a": KeyStroke(keyCode: 0, shift: false),
    "A": KeyStroke(keyCode: 0, shift: true),
    "!": KeyStroke(keyCode: 18, shift: true)
]

// A US ANSI layout, so results do not depend on the layout of the Mac running the tests.
var us: [Character: KeyStroke] = ["\n": .init(keyCode: 36, shift: false), "\t": .init(keyCode: 48, shift: false),
                                  " ": .init(keyCode: 49, shift: false)]
let usKeys: [(Character, Character, CGKeyCode)] = [
    ("a", "A", 0), ("s", "S", 1), ("d", "D", 2), ("f", "F", 3), ("h", "H", 4), ("g", "G", 5), ("z", "Z", 6),
    ("x", "X", 7), ("c", "C", 8), ("v", "V", 9), ("b", "B", 11), ("q", "Q", 12), ("w", "W", 13), ("e", "E", 14),
    ("r", "R", 15), ("y", "Y", 16), ("t", "T", 17), ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21),
    ("6", "^", 22), ("5", "%", 23), ("=", "+", 24), ("9", "(", 25), ("7", "&", 26), ("-", "_", 27), ("8", "*", 28),
    ("0", ")", 29), ("]", "}", 30), ("o", "O", 31), ("u", "U", 32), ("[", "{", 33), ("i", "I", 34), ("p", "P", 35),
    ("l", "L", 37), ("j", "J", 38), ("'", "\"", 39), ("k", "K", 40), (";", ":", 41), ("\\", "|", 42), (",", "<", 43),
    ("/", "?", 44), ("n", "N", 45), ("m", "M", 46), (".", ">", 47), ("`", "~", 50),
]
for (plain, shifted, code) in usKeys {
    us[plain] = KeyStroke(keyCode: code, shift: false)
    us[shifted] = KeyStroke(keyCode: code, shift: true)
}
let printableASCII = (32...126).map { Character(Unicode.Scalar($0)!) }

section("Quartz key events: pairing, Shift, pacing, control keys") {
    for method in TypingMethod.allCases where method != .virtualKeyboard {
        let plain = typer.events(for: "a", map: fixture, method: method, delay: 0.12)!
        check(plain.count == 2, "\(method): paired plain events")
        check(plain[0].0.type == .keyDown && plain[1].0.type == .keyUp, "\(method): key order")
        check(plain.allSatisfy { $0.0.flags.isEmpty }, "\(method): no inherited modifiers")
        check(plain[0].1 == 0.01 && plain[1].1 == 0.12, "\(method): pacing")
        for ch: Character in ["\n", "\r", "\r\n", "\t"] {
            let control = typer.events(for: ch, map: [:], method: method, delay: 0)!
            check(control.count == 2, "\(method): one pair for a control character")
            check(control[0].0.getIntegerValueField(.keyboardEventKeycode) == (ch == "\t" ? 48 : 36), "control keycode")
        }
    }
    for method in quartz {
        for ch: Character in ["A", "!"] {
            let shifted = typer.events(for: ch, map: fixture, method: method, delay: 0.12)!
            check(shifted.count == 4, "\(method): shift pair")
            check(shifted[0].0.type == .flagsChanged && shifted[3].0.type == .flagsChanged, "modifier event type")
            check(shifted[0].0.flags == .maskShift && shifted[1].0.flags == .maskShift, "shift down")
            check(shifted[2].0.flags == .maskShift && shifted[3].0.flags.isEmpty, "shift released")
            check(shifted[1].0.getIntegerValueField(.keyboardEventKeycode) == Int64(fixture[ch]!.keyCode), "physical keycode")
        }
    }
}

section("Unsupported characters are refused, never typed") {
    for method in quartz {
        check(typer.unsupported(in: "a中中🙂", map: fixture, method: method) == ["中", "🙂"], "unsupported preflight")
        check(typer.events(for: "中", map: fixture, method: method, delay: 0) == nil, "unsupported is not silently typed")
    }
    check(typer.unsupported(in: "aé", map: us, method: .virtualKeyboard) == ["é"], "accented letters are not replaced")
    let oversized = Character("a" + String(repeating: "\u{0301}", count: 25))
    check(typer.unsupported(in: String(oversized), map: [:], method: .unicode) == [oversized], "oversized Unicode preflight")
    check(typer.events(for: oversized, map: [:], method: .unicode, delay: 0) == nil, "oversized Unicode rejected")
}

section("Unicode text events round-trip") {
    for ch: Character in ["A", "中", "🙂", "👨‍👩‍👧‍👦", "•", "—"] {
        let events = typer.events(for: ch, map: [:], method: .unicode, delay: 0)!
        check(events.count == 2, "Unicode avoids Shift")
        for (event, _) in events {
            var count = 0
            var units = [UniChar](repeating: 0, count: 20)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
            check(Array(units.prefix(count)) == Array(String(ch).utf16), "Unicode UTF-16 round trip")
        }
    }
}

section("Symbol replacement") {
    let dashes: [Character: KeyStroke] = fixture.merging(["-": KeyStroke(keyCode: 27, shift: false)]) { a, _ in a }
    let swapped = typer.replacingUntypable(in: "•a—\u{200B}中", map: dashes, method: .virtualKeyboard)
    check(swapped.text == "-a--中" && swapped.replaced == 3, "symbols replaced only when the replacement has a key")
    check(typer.replacingUntypable(in: "•", map: fixture, method: .hid).replaced == 0, "no replacement without its key")
    check(typer.unsupported(in: swapped.text, map: dashes, method: .virtualKeyboard) == ["中"], "unreplaced stays unsupported")
    check(typer.replacingUntypable(in: "", map: us, method: .hid) == ("", 0), "empty text")
    check(typer.replacingUntypable(in: "a-b\r\nc", map: us, method: .hid) == ("a-b\r\nc", 0), "typeable text unchanged")
    check(typer.replacingUntypable(in: "\u{200B}\u{FEFF}", map: us, method: .hid) == ("", 2), "zero-width characters dropped")
    check(typer.replacingUntypable(in: "a\u{00A0}b", map: us, method: .virtualKeyboard).text == "a b", "non-breaking space")
    for (symbol, replacement) in Typer.replacements {
        check(replacement.allSatisfy { us[$0] != nil }, "replacement for \(symbol) is typeable on US")
        check(us[symbol] == nil, "\(symbol) has no US key, so replacing it is needed")
    }
}

section("Typing tests: short, capitals, symbols, smart symbols, long") {
    check(TypingTest.short.text == "abc123" && TypingTest.capitals.text == "AbC123!", "short samples")
    let punctuation = printableASCII.filter { !$0.isLetter && !$0.isNumber && $0 != " " }
    check(punctuation.count == 32 && TypingTest.symbols.text == String(punctuation), "symbols test has all 32 symbols in order")
    let long = TypingTest.long.text
    check((250...450).contains(long.count) && long.contains("\n") && long.contains("\t"), "long test is multi-line with Tab")
    check(Set(long.lowercased()).isSuperset(of: Set("abcdefghijklmnopqrstuvwxyz0123456789")), "long test covers every letter and digit")
    check(TypingTest.allCases.filter(\.usesSelectedSpeed) == [.long], "only the long test uses the selected speed")
    check(TypingTest.smartSymbols.text.allSatisfy { $0.isASCII || Typer.replacements[$0] != nil }, "every smart symbol has a replacement")
    let smart = typer.replacingUntypable(in: TypingTest.smartSymbols.text, map: us, method: .virtualKeyboard)
    check(smart.text == "- Bullet - en -- em \"double\" 'single' ... 3x4/2 -> <= >= != (c) (R) (TM)", "smart symbols typed as plain keys")
    check(TypingTest.smartSymbols.help.hasSuffix(smart.text), "smart symbols help shows the typed result")

    for test in TypingTest.allCases {
        for method in keyMethods {
            let text = typer.replacingUntypable(in: test.text, map: us, method: method).text
            check(typer.unsupported(in: text, map: us, method: method).isEmpty, "\(test.title) test is typeable with \(method)")
        }
        let text = typer.replacingUntypable(in: test.text, map: us, method: .hid).text
        var shiftHeld = false
        var keyDowns = 0
        for ch in text {
            guard let events = typer.events(for: ch, map: us, method: .hid, delay: 0) else {
                check(false, "\(test.title): events for \(ch.debugDescription)"); continue
            }
            for (event, _) in events {
                if event.type == .flagsChanged { shiftHeld = event.flags.contains(.maskShift) }
                if event.type == .keyDown { keyDowns += 1 }
            }
            check(!shiftHeld, "\(test.title): Shift released after \(ch.debugDescription)")
        }
        check(keyDowns == text.count, "\(test.title): one key press per character")
    }
}

section("Typing tests on this Mac's keyboard layout") {
    let layout = buildKeyMap()
    guard printableASCII.allSatisfy({ layout[$0] != nil }) else {
        print("    skipped: the current layout lacks some ASCII symbols")
        return
    }
    for test in TypingTest.allCases {
        let text = typer.replacingUntypable(in: test.text, map: layout, method: .virtualKeyboard).text
        check(typer.unsupported(in: text, map: layout, method: .virtualKeyboard).isEmpty, "\(test.title) on this layout")
    }
}

section("Line breaks as Shift+Return") {
    let shifted = Typer.shiftReturn(us)
    for ch: Character in ["\n", "\r", "\r\n"] {
        check(shifted[ch]?.keyCode == 36 && shifted[ch]?.shift == true, "\(ch.debugDescription) is Shift+Return")
        check(us[ch] == nil || us[ch]?.shift == false, "plain map keeps Return unshifted")
        for method in quartz {
            let events = typer.events(for: ch, map: shifted, method: method, delay: 0)!
            check(events.count == 4 && events[1].0.getIntegerValueField(.keyboardEventKeycode) == 36, "\(method): Shift+Return events")
            check(events[3].0.flags.isEmpty, "\(method): Shift released after Return")
        }
        check(typer.typeable(ch, map: shifted, method: .virtualKeyboard), "Virtual Keyboard can send Shift+Return")
    }
    check(shifted["\t"]?.shift == false && shifted["a"]?.shift == false, "only line breaks change")
    let separators = typer.replacingUntypable(in: "a\u{2028}b\u{2029}c\u{000B}d", map: shifted, method: .virtualKeyboard)
    check(separators.text == "a\nb\nc\nd" && shifted["\n"]?.shift == true, "other line breaks become Shift+Return")
}

section("Custom shortcut") {
    let standard = Shortcut.standard
    check(standard.problem == nil && standard.caution == nil, "Control+Backslash is allowed without a warning")
    check(standard.title.hasPrefix("⌃") && standard.title.count == 2, "default title is ⌃ and one key")
    check(Shortcut(keyCode: UInt32(kVK_Escape), modifiers: UInt32(controlKey)).problem != nil, "Esc is refused")
    check(Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: 0).problem != nil, "a plain letter is refused")
    check(Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)).problem != nil, "Shift alone is refused")
    check(Shortcut(keyCode: UInt32(kVK_F13), modifiers: 0).problem == nil, "a function key alone is allowed")
    for flag in [optionKey, cmdKey] {
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(flag))
        check(shortcut.problem == nil && shortcut.caution != nil, "Option or Command works, with a warning")
    }
    check(Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | shiftKey)).caution != nil, "Shift adds a warning")
    let all = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
    check(all.title == "⌃⌥⇧⌘F5", "modifier order in the title")
    check(Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey)).title == "⌃Space", "named keys")
    let fromEvent = Shortcut(keyCode: UInt16(kVK_ANSI_K), flags: [.control, .option])
    check(fromEvent == Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)), "event flags convert to Carbon")
}

section("Update check") {
    check(Updates.numbers("v0.3.0-beta") == [0, 3, 0] && Updates.numbers("0.3") == [0, 3], "version numbers")
    check(Updates.isNewer("0.4", than: "0.3") && Updates.isNewer("0.3.1", than: "0.3"), "newer versions")
    check(!Updates.isNewer("0.3.0", than: "0.3") && !Updates.isNewer("0.2.9", than: "0.3"), "same or older")
    check(Updates.isNewer("1.0", than: "0.10") && !Updates.isNewer("0.9", than: "0.10"), "numeric, not text, order")
    let json = """
    [{"tag_name": "v0.3.0-beta", "html_url": "https://github.com/sayre4ux/KeyTyper/releases/tag/v0.3.0-beta", "draft": false},
     {"tag_name": "v0.5.0-beta", "html_url": "https://github.com/sayre4ux/TypeThru/releases/tag/v0.5.0-beta", "draft": true},
     {"tag_name": "v0.9.0", "html_url": "https://evil.example/releases/v0.9.0", "draft": false},
     {"tag_name": "v0.8.0", "html_url": "http://github.com/sayre4ux/KeyTyper/releases/tag/v0.8.0", "draft": false},
     {"tag_name": "v0.4.1", "html_url": "https://github.com/sayre4ux/TypeThru/releases/tag/v0.4.1", "draft": false},
     {"tag_name": "nightly", "html_url": "https://github.com/sayre4ux/TypeThru/releases/tag/nightly"}]
    """
    let newest = Updates.newest(from: Data(json.utf8))
    check(newest?.version == "0.4.1", "newest release, skipping drafts, other sites, plain http, and untagged")
    check(!Updates.isReleasePage(URL(string: "https://github.com/sayre4ux/openviewer/releases/tag/v9")!), "another repository of the same owner is refused")
    check(!Updates.isReleasePage(URL(string: "file:///Applications/Calculator.app")!), "local files are refused")
    check(Updates.isReleasePage(URL(string: "https://github.com/sayre4ux/TypeThru/releases/tag/v0.3.0-beta")!), "TypeThru release pages are accepted")
    check(newest?.page.absoluteString == "https://github.com/sayre4ux/TypeThru/releases/tag/v0.4.1", "release page")
    check(Updates.newest(from: Data("not json".utf8)) == nil && Updates.newest(from: Data("[]".utf8)) == nil, "bad or empty response")
}

section("Speed levels and Virtual Keyboard timing") {
    check(abs(Typer.delay(for: 0.24) - 0.23) < 1e-9 && Typer.delay(for: 0.005) == 0, "Quartz interval")
    for (interval, hold, gap) in [(0.24, 80, 160), (0.12, 60, 60), (0.06, 30, 30), (0.03, 15, 15), (0.02, 10, 10),
                                  (0.001, 10, 10), (5.0, 80, 500)] {
        let t = VirtualKeyboard.timing(for: interval)
        check(t.hold == UInt16(hold) && t.gap == UInt16(gap), "virtual keyboard timing \(interval)")
        check((10...200).contains(t.hold) && t.gap <= 500, "timing within the helper's limits")
    }
}

section("Administrator prompt quoting") {
    check(VirtualKeyboard.shellQuoted("/A b/it's") == "'/A b/it'\\''s'", "shell quoting")
    check(VirtualKeyboard.appleScriptQuoted("say \"hi\" \\ x") == "\"say \\\"hi\\\" \\\\ x\"", "AppleScript quoting")
}

// Runs the root command as this user, with dummy files, to check the fingerprint gate.
section("Setup runs only unchanged files") {
    let resources = (ProcessInfo.processInfo.environment["TEST_DIR"] ?? NSTemporaryDirectory()) + "/Res ources"
    try? FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
    func write(_ name: String, _ text: String) { try? text.write(toFile: resources + "/" + name, atomically: true, encoding: .utf8) }
    func sha(_ name: String) -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", resources + "/" + name]
        process.standardOutput = pipe
        try? process.run(); process.waitUntilExit()
        return String(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(64))
    }
    func run(_ command: String) -> (status: Int32, output: String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe; process.standardError = pipe
        try? process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    write("setup.sh", "cd \"$(dirname \"$0\")\"; cat data.txt; echo \" ran:$1\"; ls -ld . | cut -c1-10")
    write("data.txt", "data ok")
    var hashes = ["setup.sh": sha("setup.sh"), "data.txt": sha("data.txt")]
    let command = { VirtualKeyboard.adminCommand(script: "setup.sh", files: ["data.txt"], arguments: ["501"],
                                                 resources: resources, hashes: hashes) }
    let good = run(command()!)
    check(good.status == 0 && good.output.contains("data ok ran:501"), "unchanged files run from the copy: \(good.output)")
    check(good.output.contains("drwx------"), "copies sit in a folder only the owner can open")
    write("data.txt", "data changed")
    let changed = run(command()!)
    check(changed.status == 3 && changed.output.contains("changed after download") && !changed.output.contains("ran:"),
          "a changed file stops setup before anything runs")
    write("data.txt", "data ok")
    write("setup.sh", "echo evil")
    check(run(command()!).status == 3, "a changed script does not run")
    hashes["data.txt"] = nil
    check(command() == nil, "a missing fingerprint refuses to build the command")
    hashes["data.txt"] = String(repeating: "z", count: 64)
    check(command() == nil, "a malformed fingerprint is refused")
}

print("PASS: \(checks) checks. No events posted.")
SWIFT
swiftc -module-cache-path "$TEST_DIR/module-cache" "$TEST_DIR/main.swift" -o "$TEST_DIR/tests"
TEST_DIR="$TEST_DIR" "$TEST_DIR/tests"
