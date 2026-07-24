# iosbk

`iosbk` is a macOS-native command-line tool, written in Swift, that reads an
**unencrypted** iOS backup and lets you selectively extract assets and
generate individually-installable restore artifacts — instead of an
all-or-nothing device restore.

v1 ships four plugins:

| Plugin | What it extracts | What it restores |
|---|---|---|
| **apps** | Installed third-party app bundle IDs | Curated `apps.yml` → `cfgutil install-app` or App Store "Get" links |
| **webclips** | Home-screen web clips | A single `.mobileconfig` profile |
| **wifi** | Known Wi-Fi networks (SSID only, no passwords) | A single `.mobileconfig` profile |
| **accounts** | Mail/CalDAV/CardDAV/VPN accounts (server/user only, no passwords) | A single `.mobileconfig` profile |

`iosbk` never writes to the backup it reads — every file is opened
read-only, and any SQLite database inside the backup is copied to a private
temp location before it's ever opened.

## Why not just restore the whole device?

A full device restore is all-or-nothing, slow, and forces you through
Apple's setup flow again. `iosbk` lets you cherry-pick the handful of things
that are actually annoying to redo by hand (re-adding every Wi-Fi network,
re-installing every app, re-adding mail/CalDAV/CardDAV accounts, re-adding
home-screen web clips) after a factory reset, clean re-provision, or
device-to-device move — without touching photos, messages, or app data.

## Install

Requires macOS with the Swift 6 toolchain (Xcode Command Line Tools or
Xcode).

```sh
git clone <this repo>
cd iosbk
swift build -c release
cp .build/release/iosbk /usr/local/bin/    # or anywhere on your $PATH
```

(A Homebrew formula isn't published yet — building from source with
`swift build -c release` is the supported path for now.)

## Workflow

### 1. Make an unencrypted backup

On a Mac, connect your iPhone and, in Finder (or Apple Configurator), make a
**local, unencrypted** backup — uncheck "Encrypt local backup" if it's
checked. `iosbk` cannot read encrypted backups (see [Non-goals](#non-goals)).

Backups live in:

```
~/Library/Application Support/MobileSync/Backup/<UDID>/
```

> **Note:** this directory is protected by macOS's privacy controls (TCC).
> The terminal/app you run `iosbk` from needs **Full Disk Access**
> (System Settings → Privacy & Security → Full Disk Access) to read it.

### 2. See what's there

```sh
iosbk backups                 # which backups did Finder/Configurator make?
iosbk list                    # plugins + how many items each finds (newest backup)
iosbk extract webclips        # look at the actual items before restoring
```

### 3. Reset / re-provision the device

Do your factory reset, clean re-provision, or device swap — the backup on
your Mac is untouched by any of this.

### 4. Restore what you want, one plugin at a time

**Web clips, Wi-Fi, accounts** — merge into one configuration profile and
install it:

```sh
iosbk profile webclips wifi accounts -o restore.mobileconfig
iosbk install profile restore.mobileconfig --run   # or drop --run to just print the command
```

Wi-Fi networks restored this way carry **no password** — v1 doesn't decrypt
the backup's keychain (see [Non-goals](#non-goals)), so each network shows
up pre-staged in Settings and asks for its password once (or picks it up
automatically via iCloud Keychain sign-in). Accounts likewise carry no
password — you'll be prompted to sign in once per account.

**Apps** — curate the list first (optionally enriching it with names and
their App Store id), then install:

```sh
iosbk curate apps --enrich -o apps.yml   # edit apps.yml: flip `keep: false` for anything you don't want back
iosbk install apps --from apps.yml --strategy appstore-open --run
# or, with .ipa files on hand and Apple Configurator's Automation Tools installed:
iosbk install apps --from apps.yml --strategy cfgutil --ipa-dir ~/ipas --run
```

Modern (iOS 10+) backups don't retain the actual app binary, so `apps`
only recovers bundle IDs (and, with `--enrich`, a display name + App Store
id via a lookup call — no live network access happens unless you pass
`--enrich`).

## CLI reference

```
iosbk backups                                     # detected backups: path, device, date
iosbk list [--backup DIR]                         # plugins + extract counts
iosbk extract KEY... [--backup DIR] [--json]      # inspect raw extracted items
iosbk profile KEY... [--backup DIR] -o out.mobileconfig
iosbk curate apps [--backup DIR] [--enrich] -o apps.yml
iosbk install apps --from apps.yml --strategy cfgutil --ipa-dir DIR [--run]
iosbk install apps --from apps.yml --strategy appstore-open [--run]
iosbk install profile out.mobileconfig [--run]
```

- `--backup` defaults to the newest backup under
  `~/Library/Application Support/MobileSync/Backup`; set `$IOSBK_BACKUP` to
  override the default without passing `--backup` every time.
- `--dry-run` (on `extract`/`list`/`profile`/`curate`) logs every resolved
  file/path to stderr — useful for the version-dependent wifi/accounts
  lookups.
- `--run` is required on `install …` to actually execute `cfgutil`/`open`;
  without it, the commands are only printed, so you can review or run them
  by hand.

## Non-goals (v1)

- **Encrypted-backup support.** An encrypted backup's `Manifest.db` is
  itself encrypted; `iosbk` detects this and errors out with a clear
  message rather than guessing. This is also why v1 Wi-Fi payloads carry no
  password: the password lives in the backup's encrypted keychain. See
  [docs/ROADMAP.md](docs/ROADMAP.md) for the v2 plan.
- Home-screen layout / icon arrangement (requires a supervised device).
- Photos, contacts, Wallet passes.
- Restoring per-app documents/data (no supported push channel).

## Development

```sh
swift build              # debug build
swift build -c release   # release build -> .build/release/iosbk
swift test                # deterministic unit suite, runs against synthetic fixtures only
```

### Live suite

A second, opt-in suite exercises the plugins against **the real backup on
the machine running the tests**, to confirm the version-dependent wifi and
accounts paths/schema (see `// VERIFY:` comments in `WifiPlugin.swift` and
`AccountsPlugin.swift`). It's excluded from the default `swift test` run so
CI/local runs stay deterministic:

```sh
IOSBK_LIVE=1 swift test --filter LiveBackupTests
```

This requires a real, unencrypted backup under
`~/Library/Application Support/MobileSync/Backup`, and the terminal running
the tests needs Full Disk Access (see step 1 above) — without it, macOS
reports the directory as inaccessible even if a backup is present.

#### Verified on-device

The live suite could **not** be run against a real backup in the
environment this was built in: `~/Library/Application Support/MobileSync/Backup`
is TCC-protected, the sandboxed build environment has no Full Disk Access,
and it cannot be granted non-interactively (it requires a one-time consent
click in System Settings). No real backup was present in that environment
either. As a result, the `wifi` and `accounts` `// VERIFY:` paths are
implemented defensively (multiple candidate paths/schemas, `--dry-run`
logging, graceful skip-on-missing-column) but are **unconfirmed against a
real backup**. Please run `IOSBK_LIVE=1 swift test --filter LiveBackupTests`
(with Full Disk Access granted) on a Mac with a real backup and update this
section with the confirmed path/schema.
