# AGENTS.md

Guidance for AI coding agents working on KeyTyper. Read this before changing code.

KeyTyper is a macOS menu bar app that types the clipboard as key presses into VDI and remote
desktop sessions where paste does not work. It is small (two Swift files, one C++ helper,
a few shell scripts) and has no package manager or Xcode project.

## Layout

| Path | Role |
|---|---|
| `main.swift` | App: key map from the active layout, Quartz typing methods, global hotkey, menu, onboarding, diagnostics |
| `VirtualKeyboard.swift` | Client for the root helper: macOS keycode → HID usage map, socket exchange, status |
| `helper/virtual-keyboard.cpp` | Root helper (launch daemon). Validates packets and posts HID reports to the Karabiner virtual keyboard |
| `helper/install-helper.sh` | Root-side install: driver package check/install, launch daemon |
| `helper/*.command` | User-facing setup and uninstall, opened in Terminal from the app menu |
| `build.sh` | Fetches the driver source at a pinned revision, builds and signs everything into `KeyTyper.app` |
| `test.sh` | Compiles `main.swift` without its entry point and checks event construction |

Git-ignored local state: `KeyTyper.app/`, `.build/` (driver source, module cache, last
signing identity), `.autopilot/`, `DEVLOG.md`.

## Commands

```sh
./test.sh                                                  # unit checks; posts no input
./build.sh                                                 # builds KeyTyper.app
KeyTyper.app/Contents/MacOS/KeyTyper --print-map 'text'    # keys a text would use; types nothing
KeyTyper.app/Contents/Resources/KeyTyper-VirtualKeyboard --check-protocol   # helper packet validation
```

Run `./test.sh` and `./build.sh` after every code change. Both must pass.

## What an agent must not do

- **Never post real keyboard input.** Do not trigger typing, run the menu tests, or send
  press packets to the helper. Tests construct events and inspect them; they never post.
  The readiness probe (packet `1,0,0,0,0,0,0,0`) is the only packet that is safe to send.
- **Never run the setup or uninstall scripts, or anything with `sudo`.** They change system
  state and need the user's administrator password. Ask the user to run them.
- **Never commit personal signing data**: certificate names, hashes, team IDs, or email
  addresses. `build.sh` reads the identity from the keychain at build time and stores it
  only in `.build/`. Signed app bundles contain the signer's identity, so do not commit or
  publish built apps.
- **Do not name specific VDI or remote desktop vendors** in the UI or docs. Say "VDI and
  remote desktops".
- Do not add `rm -rf` to scripts; delete specific files instead.

## Architecture

**Trigger.** A Carbon hotkey (Control+\) fires on key release. The app waits until all
modifiers and the hotkey key are up, then types into the app that was in front when the
shortcut was pressed. Typing stops on Esc or if the front app changes. The whole text is
checked against the layout before anything is sent; unsupported characters abort the run.

**Quartz methods** build a `CGEvent` pair per character (with explicit Shift
`flagsChanged` events when needed) and post them to the HID tap, the session tap, or the
target pid. Unicode mode sets the UTF-16 string on a keycode-0 event instead. All
construction is in `Typer.events(for:map:method:delay:)`, which is what `test.sh` exercises.

**Virtual Keyboard** sends one 8-byte packet per character over a Unix socket to the root
helper, which presses the key on the Karabiner DriverKit virtual keyboard:

| Byte | Meaning |
|---|---|
| 0 | Protocol version, always 1 |
| 1 | 0 = readiness probe, 1 = key press |
| 2 | HID usage (4–56 or 100) |
| 3 | Modifier: 0 none, 2 left Shift |
| 4–5 | Hold time in ms, little-endian, 10–200 (the app sends 80) |
| 6–7 | Gap after release in ms, little-endian, 0–500 |

Reply byte: 0 done or ready, 1 driver not ready, 2 invalid packet. The helper accepts
connections only from the uid given at install, via `getpeereid`. Socket:
`/var/run/local.keytyper.virtual-keyboard.sock`, mode 0600, owned by that user.

Keep the two sides in sync. A protocol change touches `VirtualKeyboard.swift`, `valid()` and
`--check-protocol` in the helper, and needs the user to rerun setup, because the installed
helper in `/Library/PrivilegedHelperTools` is a copy that `build.sh` does not update.

**Driver version** is pinned in three places: `REV` in `build.sh`, the package name in
`build.sh` and `install-helper.sh`, and the version check in `install-helper.sh`. Change
them together. Setup refuses to replace a different installed driver version, because other
apps (such as Karabiner-Elements) may depend on it.

## Design rules and why

- **The shortcut uses Control as its only modifier.** The hotkey consumes its key but not
  its modifiers, and those still reach the remote session. A lone Alt (Option) opens the
  Windows menu bar and swallows the typed text; Command may map to the Windows key; Shift
  combined with Ctrl or Alt can switch the keyboard layout. The key itself must not be a
  common Windows shortcut, because the global hotkey hides it from the remote app.
- **The README's "Privacy and security" section is a contract.** No event taps, no Input
  Monitoring, no network access at runtime, no clipboard persistence or logging, and a
  helper that can only send keys. If a change would break any of these, stop and ask. If a
  change alters what the app can see or do, update that section in the same change. Avoid
  wording in code and docs that suggests capturing or recording input.
- **Diagnostics never record clipboard contents.** Counts and reasons only.
- **Signing.** Accessibility (TCC) is tied to the code signature. Ad-hoc builds change the
  cdhash every time, so `build.sh` resets the stale entry; certificate builds keep it. Do not
  remove that reset or the identity selection.
- **Accessibility is required for every method**, including Virtual Keyboard, because
  Esc-to-stop reads key state. Relaxing this needs testing without the permission first.

## Verifying changes

Agents can verify: `./test.sh`, `./build.sh`, `--print-map`, `--check-protocol`, and
`VirtualKeyboard.status()` via the readiness probe.

Only the user can verify: real typing into a remote session, the setup and uninstall
scripts, system extension approval, and the first-run onboarding. When a change affects
these, list the exact manual steps for the user instead of claiming it works.

Untested so far: RDP and VDI clients other than the one used during development, and
signing with a self-signed certificate.

## Style

- Match the existing code: compact, few comments, comments explain why rather than what.
- Mark judgment calls with `// DECISION:` (or `# DECISION:` in shell) and a one-line reason.
- User-facing text is plain and short and tells the user the next step.
