# 📱 iosbk - iOS Backup Utility

`iosbk` is a macOS-native command-line tool, written in Swift, that reads an
iOS backup (encrypted or unencrypted) and lets you selectively extract assets
and generate individually-installable restore artifacts — instead of an
all-or-nothing device restore.

Encrypted backups are supported: pass `--password` (or set `$IOSBK_PASSWORD`)
and `iosbk` decrypts the manifest, per-file blobs, and the keychain in memory
(nothing on disk is modified). Decrypting the keychain is what lets the
**wifi** plugin recover actual Wi-Fi passwords.

`iosbk` never writes to the backup it reads — every file is opened
read-only, and any SQLite database inside the backup is copied to a private
temp location before it's ever opened.

## Supported data

### Plugins — restore via `.mobileconfig` profile

Plugins are keys you pass to `iosbk list` (to see what's found) and `iosbk
profile curate` (to build a curated `profile.yml`) — they aren't top-level
commands. For example, Wi-Fi networks aren't a `wifi` command — they're the
`wifi` plugin, used as `iosbk profile curate --keys wifi`.

| Plugin | What it recovers | Restore method |
|---|---|---|
| **webclips** | Home-screen web clips | Install a single `.mobileconfig` profile |
| **wifi** | Known Wi-Fi networks (with password, when recovered from an encrypted backup) | Install a single `.mobileconfig` profile |
| **accounts** | Mail / CalDAV / CardDAV / VPN accounts (with password/secret, when recovered from an encrypted backup) | Install a single `.mobileconfig` profile |
| **certs** | Certificates from the backup keychain (**encrypted backups only**) | Install a single `.mobileconfig` profile (one tap per cert) |

> **Web clips that run a Shortcut:** a home-screen icon added from inside
> the Shortcuts app links to `shortcuts://...&id=<UUID>&...`. That `id` is
> the shortcut's local identifier and does **not** survive a reinstall — a
> re-added `.shortcut` (or one accepted via "Allow Untrusted Shortcuts")
> always gets a brand-new UUID. `iosbk` drops the unstable `id` and keeps
> only `name` (Apple's `run-shortcut` action supports running by name), so
> the web clip works again as long as a shortcut with that **exact name**
> exists on the device. `iosbk profile curate` checks whether a matching
> shortcut was recovered from the same backup and flags each web clip in
> `profile.yml` accordingly. Local backups **do** contain the shortcut
> definitions — they live in the WorkflowKit store at
> `HomeDomain/Library/Shortcuts/Shortcuts.sqlite` — so run `iosbk shortcuts
> export` to recover them as `.shortcut` files and re-add each with its
> original name. The recovered files are **unsigned** (iOS only signs a
> shortcut server-side when you *share* it, and that signed form is never
> in a backup), so import them via Settings → Shortcuts → Advanced → "Allow
> Untrusted Shortcuts". If a web clip still comes back "not found", the
> shortcut it names was likely deleted, renamed, or never synced to this
> device — sign into the same iCloud account with Shortcuts sync enabled to
> restore it.

`apps` is also a plugin (`iosbk list` shows its count), but it restores via
its own `iosbk apps curate/download/install` workflow instead of a profile —
see [Apps](#apps) below.

`iosbk profile` is a two-step workflow, mirroring `apps curate/install`:

1. `iosbk profile curate` extracts every plugin above (or just `--keys
   webclips,wifi,...`) into **`profile.yml`** — one human-readable section
   per plugin, each item shown as a one-line description with a `keep:
   true`/`false` flag, so you can review and edit exactly what will be
   restored before anything is built. It does **not** contain passwords or
   other payload data (icons, certificate bytes, ...) — just enough to
   identify each item.
2. `iosbk profile install profile.yml` re-reads the backup, keeps only the
   items still marked `keep: true`, builds the actual `profile.mobileconfig`
   (override with `-o`), and installs it via `cfgutil` (or prints the
   command). Passwords/secrets recovered from an **encrypted** backup's
   keychain (Wi-Fi passwords, mail/VPN passwords) are included by default —
   pass `--no-passwords` to omit them. The resulting `.mobileconfig` may
   hold cleartext secrets, so treat it like a password file.



### Export commands — restorable to the device

| Command | What it copies out | How to bring it back |
|---|---|---|
| `wallet export` | Wallet passes as ready-to-use `.pkpass` files | AirDrop each `.pkpass` to your iPhone, tap to add |
| `contacts export` | All contacts as one multi-vCard `.vcf` | AirDrop the `.vcf`, tap "Add All N Contacts" |
| `calendar export` | Calendar events as `.ics` (`VEVENT`) | AirDrop/email the `.ics`; Calendar adds every event |
| `shortcuts export` | Shortcuts as individual `.shortcut` files | Enable "Allow Untrusted Shortcuts", open each and tap to add (or just sign into iCloud) |
| `photos export` | Camera Roll (`DCIM/`) | AirDrop or Finder-import |

### Dump commands — archival only (can't be restored to the device)

| Command | What it copies out | Notes |
|---|---|---|
| `reminders dump` | Reminders as `.ics` (`VTODO`) | Best-effort — no reliable iOS import; archival / CalDAV |
| `bookmarks dump` | Safari bookmarks as Netscape `bookmarks.html` | No on-device import; import into Safari on a Mac and let iCloud sync |
| `voicemail dump` | Voicemail `.amr` recordings + `index.csv` | Archival (play the audio directly) |
| `calls dump` | Call history as `calls.csv` | Archival / spreadsheet; no supported re-import |
| `bluetooth dump` | Previously-paired Bluetooth devices as a `.txt` list | Inventory only — re-pair each device by hand (pairings can't be restored) |
| `messages dump` | Raw `sms.db` + attachments | Archival / SQLite viewer; no supported silent re-import |
| `notes dump` | One `.md` file per note (`--raw` for the raw store) + `index.csv` | Read/print each note; no supported silent re-import |
| `health dump` | Raw `healthdb*.sqlite` | Archival / SQLite viewer; no supported silent re-import |

## Why not just restore the whole device?

A full device restore is all-or-nothing, slow, and forces you through
Apple's setup flow again. `iosbk` lets you cherry-pick the handful of things
that are actually annoying to redo by hand (re-adding every Wi-Fi network,
re-installing every app, re-adding mail/CalDAV/CardDAV accounts, re-adding
home-screen web clips) after a factory reset, clean re-provision, or
device-to-device move — without touching photos, messages, or app data.

## Install

Requires macOS with the Swift 6 toolchain (Xcode or Xcode Command Line Tools).

```sh
git clone <this repo>
cd iosbk
swift build -c release
cp .build/release/iosbk /usr/local/bin/    # or anywhere on your $PATH
```

A Homebrew formula isn't published yet — building from source is the
supported path for now.

## Workflow

### 1. Make a backup

Connect your iPhone and, in Finder (or Apple Configurator), make a **local**
backup. An **encrypted** backup is recommended — it's the only kind that
includes the keychain, so it's required to recover Wi-Fi passwords. Pass the
backup password with `--password` or set `$IOSBK_PASSWORD`. Unencrypted
backups also work, minus any secrets.

Backups live in:

```
~/Library/Application Support/MobileSync/Backup/<UDID>/
```

> **Note:** this directory is protected by macOS's privacy controls (TCC).
> The terminal app you run `iosbk` from needs **Full Disk Access**
> (System Settings → Privacy & Security → Full Disk Access) to read it.

### 2. See what's there

```sh
iosbk backups                 # list known backups: path, device name, date
iosbk list                    # plugins + how many items each finds (newest backup)
```

### 3. Reset / re-provision the device

Do your factory reset, clean re-provision, or device swap — the backup on
your Mac is untouched.

### 4. Restore what you want, one plugin at a time

#### Web clips, Wi-Fi, accounts

Curate what you want first, review/edit it, then install:

```sh
iosbk profile curate                  # writes profile.yml
# edit profile.yml: set keep: false for anything you don't want back

iosbk profile install --run           # rebuilds profile.mobileconfig from
                                       # the backup and installs it
```

Omit `--run` to only print the `cfgutil` command so you can review or run it
by hand. `iosbk profile curate` includes every plugin by default — pass
`--keys webclips,wifi,accounts` to curate only a subset.

`profile.yml` looks like this (one section per plugin, each item a
one-liner + a `keep` flag — delete a record or set `keep: false` to skip it):

```yaml
webclips:
  - description: "Example -> https://example.com"
    keep: true
wifi:
  - description: "HomeNet (WPA2)"
    keep: true
  - description: "CoffeeShop (None)"
    keep: false   # skipped
```

`iosbk profile install` re-reads the backup for the actual payload data —
`profile.yml` never holds passwords, icons, or certificate bytes, so it's
safe to keep in version control as a record of exactly what was restored.

Wi-Fi networks and accounts restored from an **encrypted** backup carry their
**password**/secret by default, recovered from the backup's keychain at
install time — each is restored ready to use. From an unencrypted backup (no
keychain) there's nothing to recover, so each network/account is pre-staged
and asks for its password once (or picks it up via iCloud Keychain
sign-in). Pass `--no-passwords` to omit recovered secrets even from an
encrypted backup:

```sh
iosbk profile install --no-passwords
```

The resulting `.mobileconfig` then holds cleartext secrets whenever
passwords are included — store and transmit it securely, and delete it
after installing.

**Certificates** (from an **encrypted** backup) can be curated/installed the
same way; each is installed with a single tap:

```sh
iosbk profile curate --keys certs
iosbk profile install --run
```

Note: iOS excludes installed *configuration profiles* from backups, so only
certificates held in the keychain are recoverable — not the profiles that
installed them.

#### Apps


Curate the list first (optionally enriching it with display names and App
Store IDs), then install:

```sh
iosbk apps curate --enrich
# edit apps/list.yml: set keep: false for anything you don't want back

# Re-install via the App Store (opens each app's page):
iosbk apps install --strategy appstore-open

# Or, with ipatool set up, download the .ipas first, then push via cfgutil:
iosbk apps download
iosbk apps install --strategy cfgutil
```

Add `--print-only` to either `install` command to review the commands before
they run.

Modern iOS backups don't retain the actual app binary, so `apps` recovers
bundle IDs only. With `--enrich`, `iosbk` fetches a display name and App Store
ID for each bundle ID (requires a live network connection).

### 5. Export archival data

For data that iOS doesn't support silently restoring, `iosbk` exports the raw
files (decrypted first if the backup is encrypted):

```sh
iosbk wallet export   -d out/wallet     # ready-to-AirDrop .pkpass files
iosbk photos export   -d out/photos     # Camera Roll — AirDrop / Finder-import back
iosbk messages dump   -d out/messages   # raw sms.db + attachments (archival)
iosbk health dump     -d out/health     # raw healthdb*.sqlite (archival)
```

Notes and the Bluetooth device list have their own dump commands; Shortcuts
has its own export command:

```sh
iosbk notes dump       -d out/notes            # one .md file per note + index.csv
iosbk notes dump       -d out/notes --raw      # copy the raw NoteStore.sqlite instead
iosbk shortcuts export -d out/shortcuts        # one .shortcut file per shortcut
iosbk bluetooth dump   -o out/bluetooth.txt    # list of previously-paired devices
```

- **Shortcuts** are exported as **unsigned** `.shortcut` files. To re-import,
  enable Settings → Shortcuts → Advanced → "Allow Untrusted Shortcuts", then
  open each file and tap to add it. The definitions are reconstructed from the
  WorkflowKit store at `HomeDomain/Library/Shortcuts/Shortcuts.sqlite`, so a
  local backup typically yields every shortcut on the device. They come out
  unsigned because iOS only signs a shortcut server-side when you *share* it,
  and that signed archive is never stored on-device or in a backup — so
  "restore signed as-is" isn't possible from any backup. If you'd rather not
  re-import by hand, **signing into the same iCloud account with Shortcuts
  sync enabled** brings them back automatically.
- **Bluetooth** pairings can't be restored — the dump is an inventory of
  devices to re-pair by hand.

Notes:

- **Wallet** — each pass is written as a single `.pkpass` file named after
  the pass (e.g. `Acme - Coffee Card.pkpass`). AirDrop the ones you want to
  your iPhone and tap each to add it to Wallet. `iosbk` reassembles and
  re-zips the passes for you; they're stored unpacked in the backup.
  Server-bound or expired passes (boarding passes, some tickets) may no longer
  be valid, and Apple Pay cards live in the Secure Element and are never in a
  backup.
- **Photos** is an export, not a silent restore — bring the files back via
  AirDrop or Finder.
- **Notes** are extracted into one Markdown file per note, named after the
  note's title (`Shopping-List.md`; the note's identifier or row id is used
  when it has no title), plus an `index.csv` mapping each file to its
  identifier and timestamps. Formatting (bold/italic/underline/strikethrough,
  links, headings, bullet/numbered lists, checklists) is rendered as Markdown;
  embedded tables are best-effort decoded into Markdown tables (unverified
  against real device data — falls back to a placeholder if a table can't be
  decoded). Pass `--raw` to copy the encrypted `NoteStore.sqlite` store
  instead. There's no supported re-import path.
- **Messages / Health** are dump-only for archival: the raw SQLite
  databases open in any SQLite viewer; there's no supported re-import path.
- Preset domain/paths are device-version-dependent; if a preset finds nothing,
  inspect the backup layout with `iosbk list` and `--dry-run`.

#### Contacts, calendar, reminders, bookmarks, voicemail, calls

These produce ready-to-use files rather than raw databases:

```sh
iosbk contacts export  -o contacts.vcf    # one .vcf with every contact
iosbk calendar export  -o calendar.ics    # events, re-importable via Calendar
iosbk reminders dump   -o reminders.ics   # VTODOs (best-effort, archival)
iosbk bookmarks dump   -o bookmarks.html  # Netscape HTML for Safari-on-Mac import
iosbk voicemail dump   -o out/voicemail   # .amr recordings + index.csv
iosbk calls dump       -o calls.csv       # call history as CSV
```

- **Contacts** — AirDrop the single `.vcf` to your iPhone and tap
  "Add All N Contacts" to import them all at once.
- **Calendar** — AirDrop or email `calendar.ics`; iOS Calendar adds every
  event in one step.
- **Reminders** — iOS has no reliable local `VTODO` import, so `reminders.ics`
  is for archival or import into a CalDAV/desktop client.
- **Bookmarks** — iOS can't import a bookmark file directly. Import
  `bookmarks.html` into Safari on a Mac (File → Import From → Bookmarks HTML
  File) and let iCloud sync the bookmarks to your iPhone.
- **Voicemail / Calls** — archival exports; play the `.amr` files directly or
  open the CSV in a spreadsheet.

> These read version-dependent iOS databases and are only populated from an
> **encrypted** backup (unencrypted backups omit contacts, calls, calendar,
> and reminder data). Use `--dry-run` to see which database each command
> resolved.

## CLI reference

`iosbk --help` groups every subcommand the same way this reference does:

```
iosbk backups                                                # detected backups: path, device, date
iosbk list [--backup DIR] [--password PW]                  # plugins + item counts
```

**Curate**

```
iosbk apps curate  [--backup DIR] [--password PW] [--enrich] [--dir DIR]
iosbk apps download [--dir DIR]
iosbk apps install  [--dir DIR] [--strategy cfgutil|appstore-open|html] [--print-only]
iosbk profile curate  [--keys webclips,wifi,...] [--from FILE...] [--no-passwords] [--backup DIR] [--password PW] -o out.mobileconfig
iosbk profile install out.mobileconfig [--run]
```

**Export (restorable)**

```
iosbk wallet|photos export    [--backup DIR] [--password PW] -d DIR
iosbk contacts export         [--backup DIR] [--password PW] -o contacts.vcf
iosbk calendar export         [--backup DIR] [--password PW] -o calendar.ics
iosbk shortcuts export        [--backup DIR] [--password PW] -d DIR
```

**Dump (archival only)**

```
iosbk messages|notes|health dump [--backup DIR] [--password PW] -d DIR
iosbk reminders dump   [--backup DIR] [--password PW] -o reminders.ics
iosbk bookmarks dump   [--backup DIR] [--password PW] -o bookmarks.html
iosbk voicemail dump   [--backup DIR] [--password PW] -o DIR
iosbk calls dump       [--backup DIR] [--password PW] -o calls.csv
iosbk bluetooth dump   [--backup DIR] [--password PW] -o bluetooth.txt
```

**Global options (all backup-reading commands):**

| Flag / Env var | Purpose |
|---|---|
| `--password PW` / `$IOSBK_PASSWORD` | Decrypt an encrypted backup |
| `--backup DIR` / `$IOSBK_BACKUP` | Override the default (newest) backup path |
| `--dry-run` | Log every resolved file/path to stderr without extracting |

`--backup` defaults to the newest backup under
`~/Library/Application Support/MobileSync/Backup`. `--dry-run` is useful for
debugging the version-dependent wifi and accounts lookups.

`--run` is required on `install …` to actually execute `cfgutil`/`open`;
without it, commands are only printed so you can review or run them by hand.

## Non-goals

- Home-screen layout / icon arrangement (requires a supervised device).
- Silent restore of photos, messages, notes, or Health data — iOS exposes no
  supported push channel, so these are **export-only**.
- Restoring per-app documents/data (no supported push channel).

## Development

```sh
swift build              # debug build
swift build -c release   # release build → .build/release/iosbk
swift test               # deterministic unit suite, runs against synthetic fixtures only
```

### Live suite

A second, opt-in suite exercises the plugins against the real backup on your
machine, to confirm the version-dependent wifi and accounts paths/schema (see
`// VERIFY:` comments in `WifiPlugin.swift` and `AccountsPlugin.swift`). It's
excluded from the default `swift test` run so CI stays deterministic:

```sh
IOSBK_LIVE=1 swift test --filter LiveBackupTests
```

Requires a real backup under
`~/Library/Application Support/MobileSync/Backup` (set `$IOSBK_PASSWORD` for
an encrypted one, needed to exercise the keychain Wi-Fi-password path), and
the terminal running the tests needs **Full Disk Access** — without it, macOS
reports the directory as inaccessible even if a backup is present.

> **Note:** The live suite has not yet been confirmed against a real backup in
> the environment this tool was built in (the build environment has no Full
> Disk Access). The `wifi` and `accounts` `// VERIFY:` paths are implemented
> defensively (multiple candidate paths/schemas, `--dry-run` logging, graceful
> skip-on-missing-column). Run `IOSBK_LIVE=1 swift test --filter LiveBackupTests`
> with Full Disk Access granted and update this section with confirmed results.
