<p align="center">
  <img src="docs/assets/icon.png" alt="Mactoy icon" width="160" height="160" />
</p>

<h1 align="center">Mactoy</h1>

<p align="center">
  Native macOS app for installing Ventoy on a USB drive — no Linux VM, no macFUSE, no booting a live CD just to flash a stick.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
  <a href="https://developer.apple.com/macos/"><img alt="macOS 13.5+" src="https://img.shields.io/badge/macOS-13.5+-orange"></a>
  <a href="#"><img alt="Universal (arm64 + x86_64)" src="https://img.shields.io/badge/Universal-arm64%20%2B%20x86__64-8A2BE2"></a>
  <a href="https://swift.org"><img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-blue"></a>
  <a href="https://ko-fi.com/cash508287"><img alt="Support on Ko-fi" src="https://img.shields.io/badge/Ko--fi-Support-F16061?logo=ko-fi&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://ko-fi.com/cash508287"><img alt="Support me on Ko-fi" src="https://storage.ko-fi.com/cdn/brandasset/v2/support_me_on_kofi_dark.png" height="44"></a>
</p>

> **Heads up on the icon.** The header art above is a placeholder that still has some rough edges — mixed anti-aliasing on the bezel, slightly uneven inner text rendering at small sizes. A proper redesign is in progress and will land in a future release.

## Why Mactoy exists

[Ventoy](https://www.ventoy.net) is the best way to carry a toolkit of bootable OSes on a single USB — install it once, then just drop ISOs on the drive and pick one at boot. The problem: **Ventoy has no macOS installer.** The official options are all workarounds:

- Boot the Ventoy LiveCD from a *second* USB stick, then use that to install Ventoy onto your real stick.
- Spin up a Linux VM (UTM, Parallels) with USB passthrough, then run `sh Ventoy2Disk.sh` inside it.
- Dual-boot into a Linux install you may not have.

All of these require a second machine, a second USB, or hours of setup before you can do a five-minute task. The one macOS-native alternative that actually works is a [Python proof-of-concept gist](https://gist.github.com/VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a) — which requires Homebrew (`xz`), running as `sudo`, typing raw device paths, and no progress feedback. Great that it exists. Not great to hand to a non-terminal user.

Separately, **balenaEtcher** can flash a single `.iso` to a drive, but that's not the same thing — it produces a one-boot stick, not a Ventoy multi-boot library. So mac users have been stuck picking between "flash one ISO easily" and "install Ventoy painfully."

And the [Mac App Store sandbox forbids privilege escalation and raw block-device access](#why-not-the-mac-app-store), which is exactly what a USB-flashing tool needs — so there's no polished first-party App Store option, and never will be. Every serious disk utility on macOS (Disk Utility aside) ships as a Developer ID–notarized download.

**Mactoy fills that gap.** Ventoy install from macOS, native SwiftUI, drag-and-drop, one auth prompt, Apple-notarized. It ports the Python gist's logic to Swift line-by-line (with unit tests cross-validating the GPT layout), drops it behind a Liquid Glass UI, and throws in a raw-image "just flash this one ISO" mode so you don't need Etcher for that either.

## What it does

1. **Install Ventoy** on a USB drive — download from GitHub releases, partition, write the bootloader, format the data partition as exFAT. Done from macOS, not a Linux VM.
2. **Flash a raw image** (`.iso`, `.img`, `.img.xz`, `.img.gz`) — a one-shot `dd` replacement with a progress bar and drag-and-drop. Use this when you want a single-boot stick; use Install Ventoy when you want a multi-boot library.
3. **Manage an existing Ventoy disk** — list, add, and remove ISOs on a mounted `Ventoy` volume without dropping to Finder.

Both write modes share one Liquid Glass UI and one privileged helper binary.

---

## Status — v0.2.0 alpha

- [x] GPT + boot-image math ported from the Python proof-of-concept (cross-validated: Swift and Python produce bit-identical layouts for the same disk).
- [x] Ventoy install flow end-to-end (download → extract → partition → write → format).
- [x] Raw image flashing with `.xz` and `.gz` decompression.
- [x] Liquid Glass SwiftUI interface on macOS 26 Tahoe; automatic `regularMaterial` fallback on macOS 13–15 so the same binary runs on Ventura, Sonoma, Sequoia, and Tahoe — Apple Silicon *and* Intel.
- [x] Unit tests for partition layout, GPT header/entry/CRC, MBR, plan validation, version-string allowlist.
- [x] **Developer ID signed + Apple notarized.** DMG and app are signed under the hardened runtime, notarized by Apple, and the notary ticket is stapled to the DMG. `spctl --assess` reports `accepted, source=Notarized Developer ID`.
- [x] **Verified on real hardware (Apple Silicon, macOS 26).** v0.1.3 was tested end-to-end on a 128 GB USB drive on macOS 26.2 — the resulting drive boots and runs Ventoy, and the `Ventoy` exFAT partition accepts ISO drops. v0.2.0's universal binary is static-verified (`lipo -info` reports `x86_64 arm64` on both `Mactoy` and `mactoyd`); **runtime verification on Intel Macs is pending user reports** — see *Known limitations* in the v0.2.0 release notes.
- [x] **SMAppService privileged helper.** v0.1.3 replaced the old `osascript`-based admin prompt with an XPC-based `SMAppService` LaunchDaemon — one-time approval via the native macOS "Background Items Added" flow, no password prompt per install, and XPC peer-signature verification on every connection.
- [ ] Full Disk Access (FDA) still has to be granted manually by the user; macOS deliberately does not allow apps to request FDA programmatically. The app deep-links straight to the Privacy & Security pane and walks you through it once.

## Installing

### Download

Grab `Mactoy-<version>.dmg` from the [Releases page](https://github.com/cashcon57/mactoy/releases/latest).

### Open it

1. Open `Mactoy-0.2.0.dmg`.
2. Drag `Mactoy.app` into `/Applications`.
3. Launch from Launchpad or `/Applications`. Opens normally — no right-click dance needed. The DMG is Apple-notarized, so Gatekeeper sees it as a known-good Developer ID build.

## Permissions

Mactoy asks for **two** one-time system permissions the first time you click Install Ventoy or Flash Image. Both are required by macOS to write raw bytes to an external disk — not Mactoy being paranoid. Neither has to be granted again on future runs.

### 1. Background Items (Login Items, or Login Items & Extensions on macOS 15+)

**What you'll see:** a native macOS notification, "Background Items Added — *Mactoy added an item that can run in the background.*" Clicking it opens **System Settings → General → Login Items** (macOS 13 / 14) or **Login Items & Extensions** (macOS 15 / 26), and Mactoy walks you through flipping its toggle on under **Allow in the Background**. Mactoy's in-app copy automatically uses the right pane name for your macOS version.

**Why Mactoy needs it:** direct writes to `/dev/rdisk*` require root. Apple removed most paths to elevation on modern macOS — the supported one is to register a privileged helper binary (`mactoyd`) with `launchd` via `SMAppService`. When the toggle is on, Mactoy can start the helper on demand without asking for your password every install.

**What "Background" does NOT mean here:** the helper is **not** running when Mactoy is closed, and it is **not** running at login. The toggle label is macOS UI — functionally, `mactoyd` is an on-demand XPC service that launches only when Mactoy opens a connection to it and exits as soon as the connection closes. `ps -ax | grep mactoyd` between installs shows nothing.

**Toggle it off any time:** the helper entry stays in Login Items until you remove it. Mactoy also offers an **"Uninstall the helper after this install"** checkbox on the first-time approval sheet (checked by default) that unregisters the daemon automatically once a run finishes, so the system is left clean by default.

### 2. Full Disk Access (Privacy & Security)

**What you'll see:** the first time Mactoy tries to open `/dev/rdisk<N>` the call returns *Operation not permitted*. Mactoy catches this and surfaces a **Full Disk Access needed** sheet with a one-click deep-link into **System Settings → Privacy & Security → Full Disk Access** and a "Reveal Mactoy in Finder" button so you can drag the right bundle into the list.

**Why Mactoy needs it:** macOS's TCC subsystem protects raw-disk access separately from the helper running as root. Even a `launchd`-spawned root daemon is blocked from `/dev/rdisk*` unless the responsible app has the user-granted Full Disk Access entitlement. TCC propagates the grant from `Mactoy.app` → `mactoyd` via the `AssociatedBundleIdentifiers` key in the LaunchDaemon plist, so you grant it **once to the app** and the daemon inherits.

**Why Mactoy can't ask for it automatically:** Apple deliberately does not allow apps to request Full Disk Access programmatically. There is no prompt API. Every USB-flashing tool on macOS (balenaEtcher, Raspberry Pi Imager, Ventoy itself when they ship a Mac build) has the same hand-guided step. The best a third-party app can do is deep-link to the right pane — which Mactoy does.

**What FDA does NOT let Mactoy do:** read any other files on your system. Mactoy's helper only accesses raw block devices it's been handed as part of an install plan, and refuses any plan that targets `disk0`/`disk1` or an internal volume. The grant is required because TCC's FDA toggle is the only category that covers raw-disk writes.

### Why two separate prompts?

They cover different things:

- **Login Items** is about whether Mactoy is allowed to **spawn the root helper** in the first place.
- **Full Disk Access** is about whether that root helper is allowed to **touch raw block devices** once spawned.

Either one alone isn't enough. Once both are granted, installs run without any further prompts — no passwords, no dialogs, just a progress bar.

### Why not…?

- **An admin password prompt per install?** That's what v0.1.2 did (via `osascript`). It required Full Disk Access anyway *and* asked for your password every single time. The SMAppService flow replaces that with a one-time toggle.
- **A sandbox-friendly system extension?** System extensions require an Apple-approved `com.apple.developer.driverkit.*` entitlement that isn't available to anyone outside a small whitelist. Not an option for a third-party tool.
- **Just using `diskutil`?** Apple's `diskutil` is signed with `com.apple.rootless.storage.*` entitlements that third-party apps can't replicate. It works without prompts because it's Apple code.

---

## Using Mactoy

### Install Ventoy on a USB drive

1. Plug in a USB drive. It appears in the sidebar with its friendly name and volume list.
2. Click the disk card to select it.
3. Stay on the **Install Ventoy** tab. The **Version** dropdown defaults to "Latest"; pick a specific release, or choose **Custom…** to type a tag yourself. Click **Install Ventoy**.
4. If this is your first run, follow the [Permissions](#permissions) flow once. You won't see either prompt again.
5. Confirm the erase in the **"Erase \<drive name\>?"** sheet. It lists the drive's total size, a best-effort estimate of how much data is currently on it, and the volume labels about to be wiped.
6. Wait for the progress bar. When done, the new `Ventoy` volume mounts on your Desktop.
7. Drag any `.iso`, `.img`, or `.wim` onto the `Ventoy` volume. Boot the USB on any machine and Ventoy will list the images.

### Flash a raw image

1. Switch to the **Flash Image** tab.
2. Drag an ISO / IMG onto the drop zone (or click to browse). `.xz` and `.gz` compressed images are auto-decompressed.
3. Select target disk in sidebar.
4. Click **Flash Image**, confirm the erase prompt, wait. (Same one-time [permissions](#permissions) flow as Install Ventoy — if you've already run an install the prompts won't reappear.)

### Manage ISOs on an existing Ventoy drive

1. Plug in a Ventoy-formatted USB that's already mounted.
2. Switch to the **Manage Disk** tab.
3. Add new ISOs or remove old ones without needing Finder.

## Architecture

```text
┌─────────────────────────────┐       XPC        ┌─────────────────────────────┐
│  Mactoy.app  (user, GUI)    │ ───────────────► │  mactoyd  (launchd, root)   │
│  SwiftUI + Liquid Glass     │ ◄─────────────── │  GPT writer, boot images,   │
│  DiskArbitration, URLSession│  progress stream │  newfs_exfat, fsync         │
└─────────────────────────────┘                  └─────────────────────────────┘
         │                                                    ▲
         │  SMAppService.daemon(plistName:).register()        │
         │  + NSXPCConnection(machServiceName:, .privileged)  │
         └────────────────────────────────────────────────────┘
```

- **Mactoy** — SwiftUI app. Enumerates disks, downloads Ventoy from GitHub releases, drives the UI, opens an XPC connection to `mactoyd` for each install.
- **mactoyd** — Swift CLI bundled at `Mactoy.app/Contents/MacOS/mactoyd`. Registered with `launchd` via `SMAppService` using the LaunchDaemon plist at `Mactoy.app/Contents/Library/LaunchDaemons/com.mactoy.mactoyd.plist`. Listens on the `com.mactoy.mactoyd` mach service. Verifies every connecting client's Developer ID + bundle identifier against a designated requirement before accepting an install plan. Exits after the XPC connection closes so launchd re-spawns a fresh process on the next install.
- **MactoyKit** — Swift Package with all the install logic (GPT construction, Ventoy download + extract, driver protocol, raw image flasher, XPC protocol definitions). Linked by both the app and the helper.

### Why not the Mac App Store?

The MAS sandbox forbids privilege escalation and raw block-device access, which is exactly what any USB-flashing tool needs. Privileged helper tools (SMJobBless, SMAppService, AuthorizationExecuteWithPrivileges) all require entitlements MAS review rejects, and even Full Disk Access isn't granted to sandboxed helpers. Every disk utility on macOS (Disk Utility aside) distributes outside the App Store for this reason. Mactoy ships as a Developer ID–signed, Apple-notarized DMG; a Homebrew cask is on the roadmap.

### Why not Python-wrapped-in-Swift?

The [original proof-of-concept](https://gist.github.com/VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a) that proved Ventoy can be installed from macOS without a VM is a Python script. Mactoy is a direct line-by-line Swift port. The port is cross-validated by unit tests: for the same disk size, the Swift layout math produces bit-identical output to the reference Python.

## Security model

- The helper is a proper `launchd` daemon installed via `SMAppService` — one-time user approval in **System Settings → General → Login Items & Extensions**, then no prompts on subsequent installs.
- The helper verifies every connecting XPC client's Developer ID + bundle identifier against a designated requirement before accepting any install plan. A malicious local process cannot make Mactoy's daemon do disk writes even if that process runs as root.
- The helper refuses to run without root (`getuid() == 0`) as a defensive second check.
- The helper validates the incoming plan: whole-disk BSD names only (`^disk[0-9]+$`), never `disk0` / `disk1`, external or removable volumes only, size sanity-checked.
- The helper re-probes the target disk on its own side — it does not trust the `isExternal` / `isRemovable` flags set by the app layer.
- Ventoy tarballs are SHA-256-verified against the `sha256.txt` file published alongside each Ventoy release before the bytes are handed to the driver. Cache reuse re-verifies on every install.
- The helper has a narrow entitlement set (`com.apple.security.network.client` only, to fetch the Ventoy tarball).
- See [`SECURITY.md`](SECURITY.md) for the full threat model and the remaining known limitations.

## Building from source

### Requirements

- **macOS 13.5 (Ventura) or newer** — runs on both Apple Silicon *and* Intel Macs. The 13.5 floor (rather than 13.0) is deliberate: early Ventura shipped several `SMAppService` bugs that prevented the privileged helper from registering reliably. Apple fixed those by 13.5. Liquid Glass UI kicks in automatically on macOS 26 (Tahoe); on 13.5 / 14 / 15 Mactoy falls back to a translucent `regularMaterial` look and keeps the rest of the behavior identical.
- Xcode 16+ / Swift 6.0+ (Xcode 26.2 builds it cleanly). Swift 5 toolchains will not accept the Package.swift `swift-tools-version: 6.0` header.
- `create-dmg` (for building the DMG): `brew install create-dmg`

### Build commands

```sh
git clone https://github.com/cashcon57/mactoy.git
cd mactoy

# Run tests (no root needed, no real disks touched)
swift test

# Build the app bundle (debug, native arch)
./scripts/build-app.sh

# Build the signed release bundle + DMG (requires a Developer ID cert in Keychain)
./scripts/build-app.sh release devid
./scripts/build-dmg.sh 0.2.0 devid

# Build a universal (arm64 + x86_64) app bundle — ship this if you
# want one binary that runs on both Apple Silicon and Intel Macs.
MACTOY_UNIVERSAL=1 ./scripts/build-app.sh release devid

# Open
open build/Mactoy.app
```

### Repo layout

```text
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

| Version | Feature                                                                                            |
| ------- | -------------------------------------------------------------------------------------------------- |
| v0.1    | Ventoy install + raw flash + ISO library, signed + notarized, version picker, SMAppService helper  |
| v0.2    | Universal binary (arm64 + x86_64), macOS 13.5+ support, Liquid Glass fallback (**this release**)   |
| v0.3    | Homebrew cask, first-party hardware CI, SHA256 verification UI                                     |
| v0.4    | NTFS option, per-disk exFAT label override, Sparkle auto-update                                    |
| v0.5    | Ventoy update-in-place (preserve data), plugin (JSON) editor                                       |
| v1.0    | Persistence `.dat` creator, stability pass, real-hardware Intel CI                                 |
| v1.1+   | Windows ISO driver, macOS installer USB driver                                                     |

## License

[MIT](LICENSE).

## Credits

- **Ventoy** — the bootloader that makes this useful. GPL-3. Not redistributed by Mactoy; downloaded from Ventoy's official GitHub releases at install time.
- **[VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a](https://gist.github.com/VladimirMakaev/93503ab7c63c7bf4b0cada5db726614a)** — the Python proof-of-concept that proved this was possible. Mactoy ships a Swift line-by-line port of that logic.
- **[SWCompression](https://github.com/tsolomko/SWCompression)** — pure-Swift xz/gzip decompression.
- **[create-dmg](https://github.com/create-dmg/create-dmg)** — DMG packaging.
