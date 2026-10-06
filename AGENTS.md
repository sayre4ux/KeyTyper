# AGENTS.md

Guidance for AI coding agents working on TypeThru. Read this before changing code.

TypeThru is a macOS menu bar app that types the clipboard as key presses into VDI and remote
desktop sessions where paste does not work. It is small (four Swift files, one C++ helper,
a few shell scripts) and has no package manager or Xcode project.

## Layout

| Path | Role |
|---|---|
| `main.swift` | App: key map from the active layout, Quartz typing methods, typing tests, global hotkey, onboarding, diagnostics |
| `Panel.swift` | Menu bar panel (SwiftUI, Liquid Glass on macOS 26+). A non-activating panel, so the target app stays in front |
| `Brand.swift` | The TypeThru mark, shared by the menu bar icon and the app icon |
| `icon/` | `make-icon.sh` redraws `AppIcon.icns` from `make-icon.swift`; rerun it after changing the mark |
| `docs/` | README images: logos (made by `icon/make-icon.sh`) and a panel screenshot. Update them when the icon or panel changes |
| `VirtualKeyboard.swift` | Client for the root helper: macOS keycode → HID usage map, socket exchange, status |
| `helper/virtual-keyboard.cpp` | Root helper (launch daemon). Validates packets and posts HID reports to the Karabiner virtual keyboard |
| `helper/install-helper.sh` | Root-side setup: driver package check/install, launch daemon |
| `helper/uninstall-helper.sh` | Root-side uninstall: helper, and the driver when asked |
| `build.sh` | Fetches the driver source at a pinned revision, builds and signs a universal `TypeThru.app` |
| `package.sh` | Runs `build.sh` and makes the download disk image; notarizes it when configured |
| `test.sh` | Compiles `main.swift` without its entry point and checks event construction |

Identifiers: bundle ID `io.github.sayre4ux.typethru`, launch daemon label and socket
`io.github.sayre4ux.typethru.virtual-keyboard`, helper binary `TypeThru-VirtualKeyboard`.
Builds before 0.3 were called KeyTyper and used `local.keytyper`; setup removes that old
helper and the app moves its settings over once (`migrateFromKeyTyper`). Changing an
identifier again needs the same kind of migration.

Git-ignored local state: `TypeThru.app/`, `.build/` (driver source, module cache, last
signing identity), `.autopilot/`, `DEVLOG.md`.

## Commands

```sh
./test.sh                                                  # unit checks; posts no input
./build.sh                                                 # builds TypeThru.app
TypeThru.app/Contents/MacOS/TypeThru --print-map 'text'    # keys a text would use; types nothing
TypeThru.app/Contents/Resources/TypeThru-VirtualKeyboard --check-protocol   # helper packet validation
```

Run `./test.sh` and `./build.sh` after every code change. Both must pass.

## What an agent must not do

- **Never post real keyboard input.** Do not trigger typing, run the panel's typing tests, or send
  press packets to the helper. Tests construct events and inspect them; they never post.
  The readiness probe (packet `1,0,0,0,0,0,0,0`) is the only packet that is safe to send.
- **Never run setup or uninstall (the panel items or the `helper/*.sh` scripts), or anything
  with `sudo`.** They change system state and need the user's administrator password. The
  app runs the scripts through the macOS password prompt (`VirtualKeyboard.runAsAdministrator`).
- **Never commit personal signing data**: certificate names, hashes, team IDs, or email
  addresses. `build.sh` reads the identity from the keychain at build time and stores it
  only in `.build/`. Signed app bundles contain the signer's identity, so never commit built
  apps. Publish only disk images made by `package.sh`, signed ad-hoc or with the project's
  Developer ID, and only when the user asks.
- **Do not name specific VDI or remote desktop vendors** in the UI or docs. Say "VDI and
  remote desktops".
- Do not add `rm -rf` to scripts; delete specific files instead.

## Architecture

**Trigger.** A Carbon hotkey (Control+\) fires on key release. The app waits until all
modifiers and the hotkey key are up, then types into the app that was in front when the
shortcut was pressed. `StopWatcher` polls every 10 ms while typing and stops on Esc, a new
mouse click, or a change of front app or front window (Accessibility). Return can be typed as
Shift+Return (`Typer.shiftReturn`), on by default. The whole text is
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
`/var/run/io.github.sayre4ux.typethru.virtual-keyboard.sock`, mode 0600, owned by that user.

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
- **The README's "Privacy" section is a contract.** No event taps, no Input
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

## Signing and releases

macOS ties Accessibility to the signature. `build.sh` uses the first it finds:
`TYPETHRU_SIGN_IDENTITY` (a certificate name or hash; `-` forces ad-hoc), a Developer ID
Application certificate, an Apple Development certificate, then ad-hoc. With a certificate the
permission survives rebuilds; ad-hoc builds reset it, including for the copy in Applications,
because both share the bundle ID. A self-signed certificate also works:
`TYPETHRU_SIGN_IDENTITY='TypeThru Local' ./build.sh`.

`./package.sh` builds `TypeThru-<version>.dmg`. With a Developer ID it signs with the hardened
runtime and notarizes when `TYPETHRU_NOTARY_PROFILE` names a `notarytool` keychain profile.
Releases are GitHub pre-releases with the DMG attached; bump the version in `build.sh` first.
The README keeps user steps short; put detail for contributors here.

## Verifying changes

Agents can verify: `./test.sh`, `./build.sh`, `--print-map`, `--check-protocol`, and
`VirtualKeyboard.status()` via the readiness probe.

Only the user can verify: real typing into a remote session, setup and uninstall, system
extension approval, the first-run onboarding, and installing from the disk image (Gatekeeper's
Open Anyway, the move-to-Applications check). When a change affects
these, list the exact manual steps for the user instead of claiming it works.

Untested so far: RDP and VDI clients other than the one used during development, signing
with a self-signed certificate or Developer ID, notarization, and the Intel build.

## Style

- Match the existing code: compact, few comments, comments explain why rather than what.
- Mark judgment calls with `// DECISION:` (or `# DECISION:` in shell) and a one-line reason.
- User-facing text is plain and short and tells the user the next step.
