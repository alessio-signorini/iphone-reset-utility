# iosbk v2 roadmap

v1 deliberately leaves these out of scope. This doc tracks what v2 needs to
build, and stubs that are already registrable (but not implemented) in v1.

## Encrypted-backup support

**Status:** not started. Registrable stub: none yet — `Backup.init(dir:)`
already detects an encrypted `Manifest.db` and throws `BackupError.encrypted`
with a clear message, so this is the natural extension point.

Unlocks:
- Reading an encrypted backup at all (its `Manifest.db` is itself
  encrypted).
- **Wi-Fi passwords.** The keychain (`Manifest.plist`'s `BackupKeyBag` +
  the encrypted `Manifest.db`) holds the actual Wi-Fi passwords; v1's
  `WifiPayload` deliberately omits `Password` because it can't decrypt
  them.

Where this lands in Swift: `Security.framework` (keybag/class-key unwrap)
+ `CryptoKit` (AES-CBC / PBKDF2) instead of a hand-rolled crypto stack —
this is the main reason the tool is Swift-native rather than a scripting
wrapper around `libimobiledevice`.

## Home-screen layout profile

**Status:** not started.

Restore icon positions/folders (`com.apple.homescreenlayout` payload /
`cfgutil get-icon-layout`). Requires a **supervised** device (Apple
Configurator "Prepare" flow), which is a meaningfully different device
posture than v1 targets — worth its own design pass before implementation.

## Photos / contacts / Wallet export

**Status:** not started.

Each has its own backup domain and would want its own plugin
(`PhotosPlugin`, `ContactsPlugin`, `WalletPlugin`) following the same
`ExtractorPlugin` shape as v1's plugins. Contacts/Wallet are plausible
`.mobileconfig`-adjacent or file-drop restores; Photos most likely wants a
"copy to a folder you can re-import from Photos.app" flow rather than a
push-style restore.

## Restoring per-app documents/data

**Status:** not started, and may stay that way — iOS has no supported push
channel for arbitrary per-app data outside of the app's own iCloud/Files
integration. If this ever gets built, it'll likely be per-app,
opt-in plugins rather than a generic mechanism.

## Adding new plugins

Every v1 plugin follows the same shape (`ExtractorPlugin` in
`Sources/iosbk/Core/Plugin.swift`): implement `extract(_:dryRun:)` to
produce `[Item]`, and (optionally) `payloads(_:)` to produce
`.mobileconfig` content. Register it in `Registry.all` and it picks up
`list`/`extract`/`profile` for free. `apps`-style plugins that need a
bespoke curate/install flow (rather than a payload profile) wire up their
own subcommands under `Commands/`, the same way `curate apps` / `install
apps` do.
