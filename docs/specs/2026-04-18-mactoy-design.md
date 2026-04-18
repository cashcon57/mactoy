# Mactoy — Design Specification

**Date:** 2026-04-18
**Status:** Draft (pending user approval)
**Author:** Cash Conway (with Claude)

---

## 1. Overview

**Mactoy** is a native macOS app for creating bootable USB drives. It solves two problems in one interface:

1. **Install Ventoy** on a USB drive from macOS without requiring a Linux VM, macFUSE, or the Ventoy LiveCD boot dance.
2. **Flash raw disk images** (`.iso`, `.img`, `.img.xz`) directly to USB, covering the ~90% of bootable-media needs that `dd` handles today (Linux distros, Raspberry Pi images, hybrid ISOs).

It replaces the current macOS workflow of shelling out to `dd`, running a Linux VM, or booting the Ventoy LiveCD.

### Goals

- First-class native macOS app: SwiftUI + Liquid Glass, Developer ID signed, notarized, distributed via DMG and Homebrew cask.
- Two install paths ("Ventoy" and "Flash Image") share one UI and one progress pipeline.
- ISO library management for existing Ventoy drives — add, remove, reorder ISOs on the Ventoy partition from inside the app.
- Safe by default: internal disks hidden from picker, confirmation before every destructive write, per-operation progress with cancel.

### Non-Goals (v1)

- Mac App Store distribution (incompatible with raw disk writes — see §2).
- Windows installer creation (needs NTFS + Boot Manager files — separate driver, v2+).
- macOS installer USB creation (`createinstallmedia` is Apple-only — v2+ if ever).
- Ventoy plugin editor / persistence config GUI (v2).
- Auto-update (Sparkle) — v2.

---

## 2. Context & Constraints

- **Mac App Store is blocked.** MAS sandbox forbids privilege escalation and raw disk access. Distribution path is Developer ID signed + notarized `.dmg` + Homebrew cask.
- **Root required.** Writing to `/dev/rdiskN` needs EUID 0. Delivered via a privileged LaunchDaemon managed by `SMAppService`.
- **Min macOS = 26.0 Tahoe.** Liquid Glass APIs (`.glassEffect()`, `GlassEffectContainer`) require 26+. Cuts users on 13–15; acceptable tradeoff given the requested aesthetic.
- **Dev account in hand.** Developer ID Application + Installer certificates, notarytool credentials stored in keychain.

---

## 3. User Stories

1. **First-time Ventoy user.** Plug in a USB stick, open Mactoy, click "Install Ventoy," authenticate once, watch progress bar, drag ISOs onto the now-mounted `Ventoy` volume.
2. **Existing Ventoy user.** Plug in Ventoy stick, open Mactoy, the ISO library view lists currently-installed ISOs. Drag a new ISO in or click "Remove" on an old one.
3. **One-shot Linux installer.** Plug USB, drag Ubuntu ISO onto Mactoy's "Flash Image" drop zone, pick target disk, click write.
4. **Update Ventoy.** Open Mactoy with existing Ventoy stick plugged in, banner says "Ventoy 1.1.12 available (you have 1.1.11)," click Update → reinstalls bootloader without wiping the exFAT data partition.

---

## 4. Architecture

### 4.1 Process model

```
┌──────────────────────────────┐      XPC       ┌─────────────────────────────┐
│  Mactoy.app (GUI, user)      │◄──────────────►│  com.mactoy.Mactoy.Helper   │
│  SwiftUI, Liquid Glass       │   Mach service │  LaunchDaemon, EUID 0       │
│  DiskArbitration observer    │                │  writes /dev/rdiskN         │
│  Download manager            │                │  spawns newfs_exfat         │
│  State machine               │                │  bundle-ID auth check       │
└──────────────────────────────┘                └─────────────────────────────┘
```

- **App** runs as the logged-in user. Never touches `/dev/rdisk*`. Handles UI, disk enumeration (via read-only `DiskArbitration`), network downloads, checksums, UI state.
- **Helper** is a LaunchDaemon registered via `SMAppService.daemon(plistName:)`. Bundled inside `Mactoy.app/Contents/Library/LaunchDaemons/`. Exposes an XPC service. Only writes to disk when the connecting client's code-signature bundle-ID matches `com.mactoy.Mactoy` and the audit token's team ID matches our Developer ID.
- **IPC:** NSXPCConnection with a strict `NSXPCInterface` protocol. Progress reported via reply handlers + a continuous progress callback interface.

### 4.2 Driver protocol

```swift
protocol InstallDriver {
    var id: String { get }                    // "ventoy" | "raw-dd"
    var displayName: String { get }
    func plan(target: Disk, source: Source) throws -> InstallPlan
    func execute(plan: InstallPlan,
                 progress: @escaping (ProgressUpdate) -> Void) async throws
}
```

Two implementations ship in v1:

- **`VentoyDriver`** — downloads tarball, decompresses boot images, writes GPT, writes boot.img + core.img + ventoy.disk.img, formats exFAT. Port of the patched Python script we debugged.
- **`RawImageDriver`** — detects compression (`.xz`/`.gz`/`.zst`/plain), streams decompressed bytes to `/dev/rdiskN`, fsyncs, verifies final sector count.

### 4.3 Components

| Component | Process | Purpose |
|-----------|---------|---------|
| `DiskEnumerator` | app | DiskArbitration callbacks; publishes `[Disk]` via `@Observable` |
| `DownloadManager` | app | Fetches Ventoy releases from GitHub, caches to `~/Library/Caches/Mactoy`, checksum-verified |
| `InstallPlan` | shared | Serializable struct describing all writes to perform; passed app→helper |
| `HelperClient` | app | XPC connection lifecycle, auto-reconnect |
| `HelperService` | helper | NSXPCListener, auth validator, driver dispatch |
| `DiskWriter` | helper | Raw block-device writes, 4MB buffered, fsync on completion |
| `ISOLibrary` | app | Read/write files on mounted `Ventoy` volume, no helper needed (user owns that volume) |
| `AppState` | app | `@Observable` state machine, drives UI |

### 4.4 State machine

```
idle
  → [disk selected] → sourcePicker
    → [source ready] → confirming
      → [user confirms] → authenticating
        → [SMAppService approved OR already installed] → installing
          → [success] → done
          → [failure] → error
          → [user cancel] → cancelled
      → [user cancels] → idle
```

Cancellation mid-write: app sends XPC `cancel()`, helper checks `Task.isCancelled` between 4MB chunks, closes fd, zeros first MB to prevent half-booted state.

---

## 5. UI Design

Single-window app, resizable, min 720×540. Three primary surfaces:

1. **Disk picker** (left sidebar, always visible). Liquid Glass rounded cards per external disk: icon, name, size, protocol badge (USB/Thunderbolt/SD). Internal disks never appear.
2. **Main pane** (right). Mode tabs at top: `Install Ventoy` / `Flash Image` / `Manage Disk`. Liquid Glass container groups the tab bar + content.
3. **Bottom action bar.** Big primary button (Liquid Glass interactive tinted), destructive-color when action will wipe data. Shows progress bar + cancel mid-operation.

**Liquid Glass usage:**

- `GlassEffectContainer` wraps the sidebar and the tab bar to share sampling.
- Primary action button uses `.glassEffect(.prominent.tint(.red).interactive())` when destructive, `.tint(.accentColor)` otherwise.
- Each disk card: `.glassEffect(.regular.interactive())`.
- No glass on dense content (file list, progress log) — stays readable.

**Manage Disk tab** only enabled when selected disk is a Ventoy disk (detected by presence of `VTOYEFI` partition). Shows ISO list with drag-to-add, swipe-to-delete, size-used meter.

---

## 6. Security Model

- Helper plist is embedded in the app bundle. `SMAppService.daemon(plistName:)` registers it. User sees one system dialog on first install; approves in System Settings > Login Items & Extensions.
- Helper validates every XPC client:
  - Audit token → team ID == our Developer ID team ID
  - Signing identifier == `com.mactoy.Mactoy`
  - Library Validation flag set
- Rejected connections log and disconnect.
- Helper only accepts pre-baked `InstallPlan` structs, never arbitrary shell commands. Plan fields are validated (disk path matches `/dev/rdisk[2-9][0-9]*`, never `rdisk0`/`rdisk1`; size within bounds; writes are bounded ranges).
- No network from helper — all downloads happen in the app, checksummed, then handed to helper as a file path inside a disk-image bundle.
- Uninstall: app ships a "Remove Helper" menu item → `SMAppService.unregister()`.

---

## 7. Testing Strategy

- **Unit tests** on `InstallPlan` math: GPT sector layouts, primary/backup header CRCs, partition alignment. Golden-file compare against `sgdisk -p` output for a known-good Ventoy install.
- **Driver integration tests** run against a 128MB sparse disk image file (`hdiutil create`) mounted as `/dev/diskN`. Each driver writes, we reopen and verify partition table + boot sectors via parsing.
- **XPC integration test** — spawn helper in test mode (no-op writes), assert auth rejection for unsigned test client, assert success for signed test client.
- **E2E smoke** — manual, on real USB stick, pre-release checklist. Can't automate without a USB robot.
- **Fuzzing** — plan validator fuzzed with malformed disk paths, offsets outside disk bounds, etc.

---

## 8. Distribution

- **Build:** Xcode 17 project, Swift 6, strict concurrency. Two targets: `Mactoy` (app) + `MactoyHelper` (daemon executable).
- **Signing:** Developer ID Application cert for both binaries. Hardened runtime enabled. Helper entitlements: `com.apple.security.application-groups` shared with app.
- **Notarization:** `xcrun notarytool submit --keychain-profile mactoy ...` then `stapler staple`.
- **DMG:** `create-dmg` script, drag-to-Applications layout, background image with Mactoy branding.
- **Homebrew:** `homebrew-mactoy` tap with cask pointing at latest GitHub release DMG.
- **Version cadence:** semver. Release notes in GitHub Releases.

---

## 9. Repo Structure

```
Mactoy/
├── Mactoy.xcodeproj/
├── Mactoy/                       # app target
│   ├── App.swift
│   ├── Views/
│   ├── State/
│   ├── Drivers/
│   ├── Helper/                   # client-side XPC
│   └── Resources/
├── MactoyHelper/                 # daemon target
│   ├── main.swift
│   ├── HelperService.swift
│   ├── DiskWriter.swift
│   └── Info.plist
├── MactoyKit/                    # shared SPM package
│   ├── Sources/
│   │   ├── InstallPlan.swift
│   │   ├── DriverProtocol.swift
│   │   └── XPCProtocol.swift
│   └── Tests/
├── Tests/
│   ├── MactoyTests/
│   └── MactoyHelperTests/
├── scripts/
│   ├── build-dmg.sh
│   ├── notarize.sh
│   └── release.sh
├── docs/
│   └── specs/
│       └── 2026-04-18-mactoy-design.md   (this file)
├── .github/workflows/ci.yml
├── README.md
└── LICENSE                       # MIT
```

---

## 10. Risks & Open Questions

- **SMAppService approval UX.** First-install dialog routes user to System Settings. If they skip it, helper never runs. Need in-app guidance with a "Check again" button that polls `SMAppService.status`.
- **Ventoy upstream changes.** Ventoy's boot sector layout is version-specific. We bundle no Ventoy binaries; we download from their GitHub releases. If Ventoy breaks their release format we degrade gracefully (show error, link to manual install).
- **Disk-full / flaky USB.** Mid-write errors need to leave disk in a well-defined state (zeroed first MB → unbootable but not confusing).
- **Code-signing in CI.** Every push runs build + unit/integration tests (unsigned). Tagged releases run an additional workflow that signs with Developer ID, notarizes via `notarytool`, staples, builds the DMG, and uploads to GitHub Releases. Apple ID + app-specific password + team ID live in GitHub Actions secrets, consumed only by the release workflow.
- **Liquid Glass on 25 and below.** Locked at 26+. Anyone on 13–15 is SOL for v1.

---

## 11. Roadmap

- **v1.0** (this spec) — Ventoy install, raw image flash, ISO library management, DMG + Homebrew.
- **v1.1** — Specific Ventoy version picker, SHA256 verification UI, NTFS option.
- **v1.2** — Sparkle auto-update. Ventoy update-in-place (preserve exFAT data).
- **v2.0** — Ventoy plugin editor (GUI for `ventoy.json`: themes, persistence, timeout, password). Persistence `.dat` creator.
- **v2.1** — Windows ISO → USB driver (separate implementation). macOS installer USB driver (wraps `createinstallmedia`).

---

## 12. Licensing & Credits

- **License:** MIT
- **Ventoy upstream:** GPL-3. We don't redistribute Ventoy binaries — we download from official releases at install time. No licensing incompatibility (we're a downloader, not a distributor).
- **Credit:** `VladimirMakaev` gist — original Python proof-of-concept that showed GPT+boot-img writing is feasible from macOS. README credits.
