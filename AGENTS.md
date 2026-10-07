# AGENTS.md

Guidance for AI coding agents working on TypeThru. Read this before changing code.

TypeThru is a macOS menu bar app that types the clipboard as key presses into VDI and remote
desktop sessions where paste does not work. It is small (six Swift files, one C++ helper,
a few shell scripts) and has no package manager or Xcode project; a `Makefile` runs everything.

## Layout

| Path | Role |
|---|---|
| `Makefile` | Entry point: `make build`, `test`, `package`, `icon`, `audit`, `check`, `hooks` |
| `Sources/main.swift` | App: key map from the active layout, Quartz typing methods, typing tests, global hotkey, onboarding, diagnostics |
| `Sources/Panel.swift` | Menu bar panel (SwiftUI, Liquid Glass on macOS 26+). A non-activating panel, so the target app stays in front |
| `Sources/Settings.swift` | Settings window (SwiftUI form) for rarely changed options; shares the panel's model |
| `Sources/Updates.swift` | Daily check of the GitHub releases API; shows a Download button, never installs |
| `Sources/VirtualKeyboard.swift` | Client for the root helper: keycode → HID usage map, socket exchange, status, verified root setup |
| `Sources/Brand.swift` | The TypeThru mark, shared by the menu bar icon and the app icon |
| `helper/virtual-keyboard.cpp` | Root helper (launch daemon). Validates packets and posts HID reports to the Karabiner virtual keyboard |
| `helper/protocol.hpp` | The packet check `valid()`, shared by the helper and its fuzz test |
| `helper/install-helper.sh`, `helper/uninstall-helper.sh` | Root-side setup and uninstall, bundled into the app and run behind the password prompt |
| `Tests/Tests.swift` | Unit and fuzz tests for the app (fixed seed, so failures reproduce) |
| `Tests/fuzz-protocol.cpp` | Fuzz test for `valid()` against the protocol table, with AddressSanitizer and UBSan |
| `scripts/build.sh` | Fetches the driver source at a pinned revision, builds and signs a universal `TypeThru.app` |
| `scripts/test.sh` | Runs both test suites; posts no input |
| `scripts/package.sh` | Runs `build.sh` and makes the download disk image; notarizes it when configured |
| `scripts/audit.sh` | Security and repository audit (see Before every push) |
| `scripts/check.sh` | Tests, a throwaway build, and the audit; run before every push |
| `scripts/make-icon.sh`, `scripts/make-icon.swift` | Redraw `Resources/AppIcon.icns` and the README logos |
| `Resources/AppIcon.icns` | App icon, copied into the app by `build.sh` |
| `docs/` | README images: logos and a panel screenshot. Update them when the icon or panel changes |
| `.githooks/pre-push` | Runs `scripts/check.sh` before every push (enable with `make hooks`) |
| `.github/workflows/` | CI (`make check` on macOS 26) and CodeQL code scanning (Swift and C++) |

Identifiers: bundle ID `io.github.sayre4ux.typethru`, launch daemon label and socket
`io.github.sayre4ux.typethru.virtual-keyboard`, helper binary `TypeThru-VirtualKeyboard`.
Builds before 0.3 were called KeyTyper and used `local.keytyper`; setup removes that old
helper and the app moves its settings over once (`migrateFromKeyTyper`). Changing an
identifier again needs the same kind of migration.

Git-ignored local state: `TypeThru.app/`, `*.dmg`, `.build/` (driver source, module caches,
test and check builds, last signing identity, generated `ResourceHashes.swift`), `.autopilot/`,
`DEVLOG.md` (the local development log and roadmap).

## Commands

```sh
make test                                                  # unit and fuzz tests; posts no input
make build                                                 # builds TypeThru.app
make check                                                 # everything required before a push
TypeThru.app/Contents/MacOS/TypeThru --print-map 'text'    # keys a text would use; types nothing
TypeThru.app/Contents/Resources/TypeThru-VirtualKeyboard --check-protocol   # helper packet validation
```

Run `make test` and `make build` after every code change, and `make check` before every push.
Ad-hoc `make build` resets Accessibility for the installed copy too; `make check` builds into
`.build/check` and does not.

## Before every push

`make check` runs automatically from the pre-push hook (`make hooks` once per clone) and in CI.
It must pass; `git push --no-verify` is only for emergencies. It runs:

1. **Tests**: unit tests and both fuzz suites.
2. **Build**: a full universal build into `.build/check`.
3. **Audit** (`scripts/audit.sh`, needs `brew install shellcheck gitleaks`):
   - clang static analyzer on the root helper
   - shellcheck on every script
   - gitleaks over the whole git history
   - commits to push use GitHub noreply emails
   - no build output, DMGs, DEVLOG, or `.DS_Store` tracked; nothing tracked is also ignored;
     no tracked file over 2 MB; no `rm -rf` in scripts
   - privacy contract: no event taps, logging, or clipboard writes; network only in
     `Updates.swift`; privacy-related code changes need a README Privacy update in the same push
   - no VDI vendor names in the app or README
   - the built app's signature and setup fingerprints; the installed helper's owner and modes

Also review by hand: the diff itself, and that `.gitignore` covers any new kind of local file.

## Release checklist

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `scripts/build.sh`.
2. `make check`, then `make package`.
3. Install the DMG on a clean user account or VM: Open Anyway, Accessibility, Set Up, the
   typing tests in a remote session, Settings, Check Now, Uninstall.
4. Live attack checks in a throwaway VM (only the user runs these; they need root or send keys):
   tamper with the bundled setup files and confirm Set Up refuses; send malformed and flooding
   requests to the helper socket; fake the update answer; corrupt the saved settings.
5. Push, then create a GitHub pre-release with the DMG and its SHA-256 in the notes.

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

**Trigger.** A Carbon hotkey fires on key release. It is `Shortcut.standard` (Control+\)
unless the user records another in Settings (`Shortcut`, saved as `shortcutKey` and
`shortcutModifiers`); recording uses a local key monitor on the Settings window only, with the hotkey
unregistered meanwhile. The app waits until all
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

**Root setup.** The app bundle is owned by the user, so a script in it must never run as root
directly. `build.sh` writes the SHA-256 of `install-helper.sh`, `uninstall-helper.sh`, the
helper, and the driver package into `.build/ResourceHashes.swift`, compiled into the app.
`VirtualKeyboard.adminCommand` copies the files into a new root-only folder, checks the copies
against those hashes, and runs only the copies; `test.sh` exercises this as the user with dummy
files. `install-helper.sh` also requires the driver package to be signed by its developer
(team G43BCU2T37). When adding a file that setup runs or installs, add it to both lists.

Keep the two sides in sync. A protocol change touches `VirtualKeyboard.swift`, `valid()` in
`helper/protocol.hpp`, the reference rules in `Tests/fuzz-protocol.cpp`, `--check-protocol`, and needs the user to rerun setup, because the installed
helper in `/Library/PrivilegedHelperTools` is a copy that `build.sh` does not update.

**Driver version** is pinned in three places: `REV` in `build.sh`, the package name in
`build.sh` and `install-helper.sh`, and the version check in `install-helper.sh`. Change
them together. Setup refuses to replace a different installed driver version, because other
apps (such as Karabiner-Elements) may depend on it.

## Design rules and why

- **The default shortcut uses Control as its only modifier.** Users may choose others;
  Settings warns about Option, Command, and Shift, and refuses Esc and keys with no modifier
  except F1–F20. The hotkey consumes its key but not
  its modifiers, and those still reach the remote session. A lone Alt (Option) opens the
  Windows menu bar and swallows the typed text; Command may map to the Windows key; Shift
  combined with Ctrl or Alt can switch the keyboard layout. The key itself must not be a
  common Windows shortcut, because the global hotkey hides it from the remote app.
- **The README's "Privacy" section is a contract.** No event taps, no Input Monitoring, no
  network access at runtime except the update check (GitHub releases API, at most daily, can
  be turned off, never downloads or installs), no clipboard persistence or logging, and a
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
`TYPETHRU_SIGN_IDENTITY='TypeThru Local' make build`.

`make package` builds `TypeThru-<version>.dmg`. With a Developer ID it signs with the hardened
runtime and notarizes when `TYPETHRU_NOTARY_PROFILE` names a `notarytool` keychain profile.
Releases are GitHub pre-releases with the DMG attached; bump the version in `build.sh` first.
The README keeps user steps short; put detail for contributors here.

## Verifying changes

Agents can verify: `make check` (and its parts), `--print-map`, `--check-protocol`, and
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
