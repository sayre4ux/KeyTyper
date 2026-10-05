#!/bin/sh
# Exercise actual event construction without posting any input or reading the clipboard.
set -eu
cd "$(dirname "$0")"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/keytyper-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT HUP INT TERM
cat VirtualKeyboard.swift > "$TEST_DIR/main.swift"
sed '/^\/\/ MARK: - Entry point/,$d' main.swift >> "$TEST_DIR/main.swift"
cat >> "$TEST_DIR/main.swift" <<'SWIFT'

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let typer = Typer()
let fixture: [Character: KeyStroke] = [
    "a": KeyStroke(keyCode: 0, shift: false),
    "A": KeyStroke(keyCode: 0, shift: true),
    "!": KeyStroke(keyCode: 18, shift: true)
]
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
    if method != .unicode {
        for ch: Character in ["A", "!"] {
            let shifted = typer.events(for: ch, map: fixture, method: method, delay: 0.12)!
            check(shifted.count == 4, "\(method): shift pair")
            check(shifted[0].0.type == .flagsChanged && shifted[3].0.type == .flagsChanged, "modifier event type")
            check(shifted[0].0.flags == .maskShift && shifted[1].0.flags == .maskShift, "shift down")
            check(shifted[2].0.flags == .maskShift && shifted[3].0.flags.isEmpty, "shift released")
            check(shifted[1].0.getIntegerValueField(.keyboardEventKeycode) == Int64(fixture[ch]!.keyCode), "physical keycode")
        }
        check(typer.unsupported(in: "a中中🙂", map: fixture, method: method) == ["中", "🙂"], "unsupported preflight")
        check(typer.events(for: "中", map: fixture, method: method, delay: 0) == nil, "unsupported is not silently typed")
    }
}
for ch: Character in ["A", "中", "🙂", "👨‍👩‍👧‍👦"] {
    let events = typer.events(for: ch, map: [:], method: .unicode, delay: 0)!
    check(events.count == 2, "Unicode avoids Shift")
    for (event, _) in events {
        var count = 0
        var units = [UniChar](repeating: 0, count: 20)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        check(Array(units.prefix(count)) == Array(String(ch).utf16), "Unicode UTF-16 round trip")
    }
}
let oversized = Character("a" + String(repeating: "\u{0301}", count: 25))
check(typer.unsupported(in: String(oversized), map: [:], method: .unicode) == [oversized], "oversized Unicode preflight")
check(typer.events(for: oversized, map: [:], method: .unicode, delay: 0) == nil, "oversized Unicode rejected")
print("PASS: four modes, event pairing, Shift release, pacing, control keys, unsupported input, and Unicode round trips. No events posted.")
SWIFT
swiftc -module-cache-path "$TEST_DIR/module-cache" "$TEST_DIR/main.swift" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
