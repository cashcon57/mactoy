# Mactoy

> Native macOS app for creating bootable USB drives. Installs Ventoy or flashes raw disk images without needing a Linux VM, macFUSE, or the Ventoy LiveCD boot detour.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 26+](https://img.shields.io/badge/macOS-26+-orange)](https://developer.apple.com/macos/)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-blue)](https://swift.org)

Mactoy is a SwiftUI utility that does two things well:

1. **Install Ventoy** on a USB drive — download, partition, write the bootloader, format the data partition. Done from macOS, not a Linux VM.
2. **Flash a raw image** (`.iso`, `.img`, `.img.xz`, `.img.gz`) — a one-shot `dd` replacement with a progress bar and drag-and-drop.

Both modes share one clean Liquid Glass UI.

---

## Status — v0.1.0 alpha

- [x] GPT + boot-image math ported from the Python proof-of-concept (cross-validated: Swift and Python produce bit-identical layouts for the same disk).
- [x] Ventoy install flow end-to-end (download → extract → partition → write → format).
- [x] Raw image flashing with `.xz` and `.gz` decompression.
- [x] Liquid Glass SwiftUI interface (macOS 26 Tahoe).
- [x] Unit tests for partition layout, GPT header/entry/CRC, MBR, and plan validation.
- [ ] **Not yet signed with Developer ID.** The initial v0.1.0 DMG is ad-hoc signed — Gatekeeper will warn. See [Installing](#installing) for the right-click workaround.
- [ ] **Not yet notarized.** Notarization + Developer ID signing are planned for v0.2.
- [ ] **Not yet verified on real hardware by the author.** The code is a faithful port of a Python script that successfully flashed a Ventoy drive on the same machine this was built on; first-party hardware confirmation comes in v0.1.1.
- [ ] SMAppService privileged helper (currently uses `osascript`-based admin prompt; migration to SMAppService is planned for v0.2).

## Installing

### Download

Grab `Mactoy-<version>.dmg` from the [Releases page](https://github.com/cashcon57/mactoy/releases/latest).

### Open it (first time, unsigned build)

Because v0.1.0 is ad-hoc signed, macOS Gatekeeper will block the first launch. Once:

1. Drag `Mactoy.app` into `/Applications`.
2. Control-click `Mactoy.app` in Applications → **Open** → **Open** again at the confirm dialog.
3. Subsequent launches work normally.

Alternative, from Terminal:

```sh
xattr -cr /Applications/Mactoy.app
open /Applications/Mactoy.app
```

## Using Mactoy

### Install Ventoy on a USB drive

1. Plug in a USB drive. It appears in the sidebar.
2. Click the disk card to select it.
3. Stay on the **Install Ventoy** tab, leave version blank for latest, click **Install Ventoy**.
4. Authenticate when macOS asks for admin rights (this is needed to write raw bytes to the disk; see [Security](#security-model)).
5. Wait for the progress bar. When done, the new `Ventoy` volume mounts on your Desktop.
6. Drag any `.iso`, `.img`, or `.wim` onto the `Ventoy` volume. Boot the USB on any machine and Ventoy will list the images.

### Flash a raw image

1. Switch to the **Flash Image** tab.
2. Drag an ISO / IMG onto the drop zone (or click to browse). `.xz` and `.gz` compressed images are auto-decompressed.
3. Select target disk in sidebar.
4. Click **Flash Image**, authenticate, wait.

### Manage ISOs on an existing Ventoy drive

1. Plug in a Ventoy-formatted USB that's already mounted.
2. Switch to the **Manage Disk** tab.
3. Add new ISOs or remove old ones without needing Finder.

## Architecture

```
┌─────────────────────────────┐   stdin: plan JSON   ┌─────────────────────────────┐
│  Mactoy.app  (user, GUI)    │ ───────────────────► │  mactoyd  (helper, root)    │
│  SwiftUI + Liquid Glass     │ ◄─────────────────── │  GPT writer, boot images,   │
│  DiskArbitration, URLSession│   stdout: NDJSON     │  newfs_exfat, fsync         │
└─────────────────────────────┘      progress        └─────────────────────────────┘
         │                                                        ▲
         │  osascript admin prompt                                │
         └────────────────────────────────────────────────────────┘
```

- **Mactoy** — SwiftUI app. Enumerates disks, downloads Ventoy from GitHub releases, drives the UI, launches `mactoyd` under admin privileges via `osascript` (one auth prompt per install).
- **mactoyd** — tiny Swift CLI bundled inside `Mactoy.app/Contents/Resources/`. Reads a JSON `InstallPlan` from stdin, writes to `/dev/rdiskN`, reports NDJSON progress to stdout. Refuses to run unless EUID 0.
- **MactoyKit** — Swift Package with all the install logic (GPT construction, Ventoy download + extract, driver protocol, raw image flasher). Linked by both the app and the helper.

### Why not the Mac App Store?

The MAS sandbox forbids privilege escalation and raw block-device access, which is exactly what any USB-flashing tool needs. Every disk utility on macOS (Disk Utility, balenaEtcher, Rufus-alternatives) distributes outside the App Store for this reason. The planned v0.2 path is Developer ID signed + notarized DMG + Homebrew cask.

### Why not Python-wrapped-in-Swift?

The [original proof-of-concept](https://gist.github.com/VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a) that proved Ventoy can be installed from macOS without a VM is a Python script. Mactoy is a direct line-by-line Swift port. The port is cross-validated by unit tests: for the same disk size, the Swift layout math produces bit-identical output to the reference Python.

## Security model

- The helper binary is only invoked via `osascript` admin prompt — one authentication per install run.
- The helper refuses to run without root (`getuid() == 0`).
- The helper validates the incoming plan: no `disk0`/`disk1`, only external or removable volumes, size sanity-checked.
- The helper does not accept arbitrary shell commands. It reads a strongly-typed `InstallPlan` struct from stdin.
- No network access from the helper. All downloads happen in the user-privilege app.

## Building from source

### Requirements

- macOS 26 (Tahoe) or newer
- Xcode 26.2+ (Swift 6.2)
- `create-dmg` (for building the DMG): `brew install create-dmg`

### Build commands

```sh
git clone https://github.com/cashcon57/mactoy.git
cd mactoy

# Run tests (no root needed, no real disks touched)
swift test

# Build the app bundle (debug)
./scripts/build-app.sh

# Build the signed release bundle + DMG
./scripts/build-app.sh release sign
./scripts/build-dmg.sh 0.1.0

# Open
open build/Mactoy.app
```

### Repo layout

```
Mactoy/
├── Package.swift
├── Sources/
│   ├── MactoyKit/           shared library (GPT, drivers, plan)
│   ├── mactoyd/             privileged helper CLI
│   └── Mactoy/              SwiftUI app
├── Tests/MactoyKitTests/    unit tests for GPT + plan
├── app-support/             Info.plist (outside SPM resources)
├── scripts/                 build-app.sh, build-dmg.sh
├── docs/specs/              design specs
└── build/                   (git-ignored) .app + .dmg output
```

## Roadmap

| Version | Feature |
|---------|---------|
| v0.1    | Ventoy install + raw flash + ISO library (this release) |
| v0.2    | Developer ID signing + notarization + SMAppService helper + Homebrew cask |
| v0.3    | Specific Ventoy version picker, SHA256 verification UI |
| v0.4    | Sparkle auto-update, Ventoy update-in-place (preserve data) |
| v1.0    | Ventoy plugin (JSON) editor, persistence `.dat` creator, stability pass |
| v1.1+   | Windows ISO driver, macOS installer USB driver |

## License

[MIT](LICENSE).

## Credits

- **Ventoy** — the bootloader that makes this useful. GPL-3. Not redistributed by Mactoy; downloaded from Ventoy's official GitHub releases at install time.
- **[VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a](https://gist.github.com/VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a)** — the Python proof-of-concept that proved this was possible. Mactoy ships a Swift line-by-line port of that logic.
- **[SWCompression](https://github.com/tsolomko/SWCompression)** — pure-Swift xz/gzip decompression.
- **[create-dmg](https://github.com/create-dmg/create-dmg)** — DMG packaging.
