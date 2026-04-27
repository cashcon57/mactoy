# Changelog

## [0.3.0] — 2026-04-27

Adds **Update Ventoy** — a fourth top-level mode that updates an existing Ventoy install to a new version *without* erasing the user's ISOs or `/ventoy/` config. Mactoy is now the first non-official-Ventoy-team port of the in-place update flow.

### Added

- **Update Ventoy mode.** New tab in the sidebar, alongside Install Ventoy / Flash Image / Manage Disk. Adapts to the disk you've selected:
  - Disk has Ventoy and a newer release exists → "Update available — installed v1.0.99, latest v1.1.05" with a single-click update CTA.
  - Disk is up to date → "Already up to date" with a hint that the Install Ventoy tab can wipe-and-reinstall if desired.
  - Disk has the partition geometry of a damaged Ventoy install → "Repair via fresh install (erases ISOs)" hint pointing at the Install Ventoy tab.
  - Disk doesn't have Ventoy → "no Ventoy detected" with a pointer to the Install Ventoy tab.
- **`VentoyVersionProbe` + `FAT16Reader` (`Sources/MactoyKit/`).** Pure-Swift FAT16 read-only parser, plus a Ventoy-specific probe layer that locates partition 2, validates the layout (`partition 1 starts at sector 2048`, `partition 2 size == 65536 sectors`, partition 2 is FAT16 with `VTOYEFI` label), reads `/grub/grub.cfg`, and extracts the `set VENTOY_VERSION="X"` string. Future-compat: makes no assumptions about specific Ventoy versions, so a hypothetical 2.0 or 1.2.0-rc1 release is detected automatically as long as it preserves the on-disk layout (which has been stable since Ventoy 1.0.0).
- **`VentoyDriver.update(plan:progress:)`.** Byte-level update flow that mirrors `Ventoy2Disk.sh --update`: preserve the Ventoy disk UUID (16 bytes at LBA 0 offset 384) + the 8 reserved sectors at LBA 2040 + the user's secure-boot toggle (offsets 92, 17908) → rewrite MBR boot code (bytes 0–439) → restore UUID → write GRUB2 core image at LBA 34 (GPT) or LBA 1 (MBR) → restore secure-boot bytes → overwrite the entire 32 MiB VTOYEFI partition with the new disk image → restore reserved sectors. Partition 1 is **never** written — by design, not by transactional magic.
- **`probeVentoy` XPC method on `mactoyd`.** Read-only; safe to call as the user changes their disk selection. The Mactoy app debounces probe RPCs at 300 ms so rapid sidebar selection changes don't pile up XPC round trips.
- **`VentoyOperation` field on `InstallPlan`** (`.freshInstall` | `.updateInPlace`). Backwards-compatible decode: v0.2.x plans without the field decode as `.freshInstall`, so a daemon during a rolling upgrade can still execute legacy plans.
- **14 new unit tests** covering `parseVentoyVersion` regex (single/double/un-quoted, whitespace tolerance, future-format-tolerant 4-component and alphanumeric suffixes), `VentoyProbeResult` codable round-trip, and `InstallPlan` v1→v2 backwards-compat decode.

### Changed

- **`AppMode` gained `.updateVentoy`** → 4 sidebar tabs instead of 3. Symbol: `arrow.triangle.2.circlepath`. Display name: "Update Ventoy".
- **`EraseConfirmationSheet`** adapts to the operation: for an update it shows non-destructive copy ("ISOs and `/ventoy/` config will be preserved … don't unplug — interruption requires re-running but your data stays safe"), an accent-colored Update button instead of a red Erase button, and hides the "volumes that will be erased" list (nothing's being erased).
- **`ActionBar`'s primary button** picks up "Update Ventoy" copy + accent tint when in update mode, distinguishing it visually from the destructive Install/Flash actions.
- **`mactoydVersion`** bumped 0.2.1 → 0.3.0.

### Known limitations

- **No transactional rollback during update.** Power loss or USB unplug mid-update (~5 seconds total) leaves the bootloader in a half-written state — re-run update to recover. Partition 1 (your ISOs) is never at risk because the update flow doesn't write there.
- **No real-hardware Intel smoke test for the update flow.** Static + parser-level testing only. Real-world validation will come from user reports.

## [0.2.1] — 2026-04-25

Hotfix release. v0.2.0 shipped four memory + responsiveness regressions caused by the @Observable → ObservableObject migration in v0.2.0. A user on a MacBook Air M4 reported runaway memory pressure during a flash that froze other apps, followed by repeated crashes on relaunch. This release addresses the verifiable causes of that pressure and adds `os.Logger` instrumentation so future incidents come with a usable diagnostic trail.

### Fixed

- **`ProgressForwarder` now throttles XPC progress callbacks to ~30 Hz.** v0.2.0 spawned a `Task { @MainActor in onUpdate(update) }` for every progress update received from the daemon. On a multi-GB image this was hundreds of tasks per second, each one writing twice to `@Published` properties (`log.append` + `status = .running`) and re-rendering every `@EnvironmentObject` subscriber. The throttle preserves all phase transitions and terminal `.done` / `.failed` events; only intra-phase progress ticks are coalesced. Lives in `Sources/Mactoy/HelperInvoker.swift`.
- **`AppState.log` is now bounded to the most recent 500 entries.** v0.2.0 appended every `ProgressUpdate` to `log` indefinitely with no consumer. A long install accumulated thousands of entries and pinned them in memory. The new `appendBoundedLog` helper drops the oldest 25% in one shot rather than `removeFirst()` per append.
- **Equality-guarded `@Published` assigns in the disk-enumeration loop, the version fetch, the helper-status poll, and `refreshHelperStatus`.** Combine's `@Published` fires `objectWillChange` on every assignment regardless of whether the value actually changed — and v0.2.0 was reassigning identical disk lists every 2 seconds and identical helper statuses every 1 second. Each assignment invalidated every view subscribed via `@EnvironmentObject`. Now we only assign when the new value differs. (`@Observable`, which we used in v0.1.x, did this comparison automatically — `@Published` does not, and that gap was the regression.) Side effect of the `refreshHelperStatus` guard: the **"remove the helper after this install"** checkbox no longer resets to its default on every status refresh. Users who manually toggle it now keep their choice across status changes — matches v0.1.x behaviour, which v0.2.0 had unintentionally regressed by re-deriving the value on every poll.
- **`ProgressForwarder` flushes the last throttled-out update before delivering a phase transition or terminal `.done`/`.failed`.** Without this, a fast NVMe stick that hits "writing 99.9%" within 33 ms of "done" would have its 99.9% frame silently dropped — the user would see the bar freeze around 95% and then jump to "Install complete." Now the throttle keeps the most recent dropped update buffered and flushes it as soon as the next non-throttled update arrives.
- **`UTType(filenameExtension:)!` force-unwraps in the file picker.** Replaced four force-unwraps with a `compactMap` so a degraded CoreServices type registry can no longer crash the Flash Image picker.

### Added

- **`os.Logger` instrumentation across the launch path, helper lifecycle, `run()` state transitions, and the daemon.** Subsystem `com.mactoy`, categories `lifecycle`, `appstate`, `xpc.progress`, `mactoyd`. Users hitting future bugs can now attach output from `log show --predicate 'subsystem == "com.mactoy"' --last 1h --info --debug > mactoy.log` to a GitHub issue. Documented in README under "Reporting bugs".
- **`DiskTarget` now conforms to `Equatable`** in `MactoyKit`, so the disk-enumeration equality guard can compare full structs instead of approximating via `bsdName`.

### Pulled

- **v0.2.0 was retroactively marked as a prerelease on GitHub.** The "latest" tag now resolves to v0.1.4 until v0.2.1 ships. v0.2.0 is still downloadable for forensic reasons but new users get directed to a stable build.

## [0.2.0] — 2026-04-23

Mactoy drops down to **macOS 13.5 Ventura** and ships as a **universal (arm64 + x86_64) binary**, so the same `Mactoy-0.2.0.dmg` runs on Intel Macs, older Apple Silicon, and OCLP-patched hardware — not just macOS 26 Tahoe. Liquid Glass stays on Tahoe; older macOS gets an automatic `regularMaterial` fallback that reads as translucent cards without the real glass.

### Added

- **Universal build support.** `MACTOY_UNIVERSAL=1 ./scripts/build-app.sh release devid` produces a fat binary (`lipo -info` reports `x86_64 arm64`) with one `codesign` pass that signs both slices under the hardened runtime. Default builds stay native-arch for dev speed.
- **`.mactoyGlass(cornerRadius:tint:interactive:)` view modifier + `MactoyGlassContainer`** in `Sources/Mactoy/Views/LiquidGlass.swift`. On macOS 26 it applies `glassEffect(...)` / `GlassEffectContainer` directly; on 13.5 / 14 / 15 it falls back to `.regularMaterial` inside a rounded shape (or `Capsule()` when no radius is specified) with an optional tint overlay and a 0.5pt `Color.primary.opacity(0.08)` stroke. Every previous `.glassEffect(...)` and `GlassEffectContainer { }` call migrated to the helper.
- **`SystemSettingsStrings.loginItemsPane`** helper that returns `"Login Items"` on macOS 13/14 and `"Login Items & Extensions"` on 15+. All user-facing copy in `HelperExplainerSheet`, `HelperAwaitingApprovalSheet`, and the two `status = .failed(...)` messages in `AppState` now use it — Ventura users no longer see instructions pointing at a pane that doesn't exist on their system.

### Changed

- **Minimum macOS 26.0 → 13.5 (Ventura).** `Package.swift` platform and `Info.plist` `LSMinimumSystemVersion` both pinned to 13.5. The 13.5 floor (rather than 13.0) is deliberate: `SMAppService.register()` shipped with multiple bugs in early Ventura (register returning success while launchd never loaded, BTM/launchd desync surviving reboots, `Operation not permitted` re-register loops). Apple fixed them by 13.5 / 14.2.
- **Reactive architecture: `@Observable` → `ObservableObject` + `@Published`.** `AppState` is now a `@MainActor final class AppState: ObservableObject` with `@Published` on every stored property. `MactoyApp` uses `@StateObject` + `.environmentObject(appState)`. Every view swapped `@Environment(AppState.self)` + `@Bindable var state = state` for `@EnvironmentObject var state: AppState` (which provides `$state.foo` bindings via dynamic member lookup automatically). Drops the dependency on the macOS 14+ Observation framework.
- **`.onChange(of:) { _, new in }` → `{ new in }`** in `HelperAwaitingApprovalSheet`. The two-arg closure overload is macOS 14+; the single-arg form is available since macOS 12.
- **README requirements + badges.** macOS badge reads `13.5+` with a new "Universal (arm64 + x86_64)" badge alongside. Build-from-source section now lists Xcode 16+ / Swift 6.0+ (Package manifest uses `swift-tools-version: 6.0`, which Swift 5 toolchains can't parse).

### Fixed

- **Fallback capsule shape.** The first cut of the glass fallback used `RoundedRectangle(cornerRadius: 999, style: .continuous)` as a "capsule" substitute. SwiftUI clamps the corner radius to `min(w,h)/2` but the `.continuous` style produces flatter sides than `Capsule()` on wider chips — ModeTab chips on Ventura would have looked slightly wrong. Fallback now branches on `cornerRadius == nil` and uses `Capsule(style: .continuous)` via a generic `glassStack<S: InsettableShape>(_:)` helper.
- **Bash 3.2 compatibility in `scripts/build-app.sh`.** `"${ARCH_ARGS[@]}"` on an empty array trips `set -u` on macOS-shipped bash 3.2 at `/bin/bash`. Swapped to the `${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}` idiom so the script works under both Homebrew bash 5 and system bash 3.2.

### Verified

- `swift build -c release` clean on both `Mactoy` and `mactoyd`.
- `swift build -c release --arch arm64 --arch x86_64` produces fat binaries for both products; `lipo -info build/Mactoy.app/Contents/MacOS/Mactoy` and `.../mactoyd` both report `x86_64 arm64`.
- `swift test` — 16/16 tests pass.
- Real-hardware smoke test on Intel Ventura **not** performed (no Intel Mac available). Universal-slice verification is from `file` / `lipo` static analysis. Runtime behaviour on Intel will be validated via user testing.

## [0.1.4] — 2026-04-21

Applies the same disk-handling fixes that unblocked Install Ventoy in v0.1.3 to the other two tabs, and tightens Manage Disk so it binds to the selected drive instead of any volume named `Ventoy`.

### Fixed

- **Flash Image: release raw-disk fd before asking macOS to re-probe.** `RawImageDriver` now explicitly `close()`es the `DiskWriter` after `fsync` (same fix applied to `VentoyDriver` in v0.1.3) and calls `diskutil reloadDisk` + `mountDisk` so whatever filesystem lives on the flashed image is picked up by macOS automatically. Previously the flashed drive might not mount until the user unplugged and replugged it.
- **Manage Disk: match the `Ventoy` volume to the selected disk.** Previously the tab would happily show the ISO list from *any* volume named `Ventoy` mounted on the system. If you had two Ventoy sticks plugged in, you might have been editing the wrong one. The panel now uses `diskutil info` to confirm the volume's `DeviceIdentifier` actually sits on the currently-selected BSD disk.
- **Manage Disk: ISO list refreshes when you switch drives.** `.id(volumeURL)` now forces the embedded list to rebuild when the user picks a different disk, instead of keeping stale items from the previously-selected drive.
- **Manage Disk: surface copy / delete errors.** The Add ISO and trash-button actions previously used `try?` and silently swallowed failures. Both now raise an `NSAlert` with the underlying error.

### Added

- **Manage Disk: Refresh button** and an ISO-count header (`N ISOs on this drive` / `No ISOs on this drive yet`).

### Docs

- README status section bumped to v0.1.3 alpha with the **"Verified on real hardware"** checkmark.
- Architecture diagram + Security model rewritten for the XPC-based SMAppService daemon flow. Removes lingering `osascript` references.
- Install step updated to reference `Mactoy-0.1.3.dmg`.

## [0.1.3] — 2026-04-21

This is the first release that has been end-to-end verified on real hardware — Ventoy installs to a real USB stick, boots, and works. Every previous release had a disk-writing bug hiding behind the permission wall.

### Added

- **First-time helper setup flow.** A pre-approval sheet explains what the background helper does before macOS shows its "Background Items Added" prompt, including why the helper is needed and that it does not actually run in the background. Ships with a "Remove the helper after this install" toggle (default on) so the system is left clean.
- **Full Disk Access guidance sheet.** When macOS TCC blocks raw-disk access the app surfaces a numbered-step remediation sheet with a deep-link straight into the Privacy & Security pane. Apple does not allow apps to request FDA programmatically — this is the cleanest UX possible.
- **Live download progress.** The Ventoy tarball download now reports incremental bytes-done / bytes-total instead of a single indeterminate sweep.
- **Auto-recovery for BTM/launchd desync.** If the daemon's Login Items toggle is on but launchd has no live registration, the app transparently re-registers and retries the install instead of surfacing a generic "No such process" error.

### Changed

- **XPC-based helper architecture.** The privileged `mactoyd` helper now runs as a `SMAppService` LaunchDaemon and communicates with the app over XPC. Replaces the previous `osascript` admin-prompt invocation, which prompted for a password every install and required users to grant Full Disk Access by hand. Also closes security issue C2 — XPC peer authentication now verifies the connecting client's Developer ID + bundle identifier against the daemon's expected requirement before accepting any install plan.
- **Daemon auto-exits after the XPC connection closes** so launchd re-spawns a fresh process on each install. Without this, a stale daemon from an earlier app launch could service new installs with out-of-date code.
- **Ventoy boot-image layout paths updated for Ventoy 1.1.11+.** Upstream moved `ventoy.disk.img.xz` from `boot/` to `ventoy/`; the driver now searches both locations so older and newer Ventoy releases both work.

### Fixed

- **Post-install format step no longer races macOS's partition-table re-scan.** The previous flow unmounted the disk and then immediately ran `newfs_exfat /dev/diskNs1`, which failed on most disks because macOS hadn't yet noticed the new partitions. The driver now calls `diskutil reloadDisk` and polls the `/dev` tree (up to 90 s, retrying every 10 s) before attempting the format.
- **`DiskWriter` releases its raw-disk fd before the re-scan.** Previously the Swift class held `/dev/rdisk*` open until its `deinit`, which happens at the end of `execute()` — long after we needed macOS to re-probe the partition table. The kernel refuses to re-scan a disk that still has an open writer, so the wait loop was polling a disk its own process was preventing from updating. Now we explicitly `close()` after `fsync` and before asking `diskutil` to reload.
- **UI no longer shows "Failed" + progress bar + "Working…" button simultaneously.** A terminal `.failed` progress update arriving after the XPC reply's `status = .failed` used to overwrite the failure state with `.running(phase: .failed)`. Terminal phases (`.failed`, `.done`) are now ignored by the per-update handler — the XPC reply decides the final state.
- **Status-row / error bubbles no longer render as capsules.** `.glassEffect(.regular, in: .rect(cornerRadius: 16))` replaces the default capsule shape (matching the fix applied to the info panels in v0.1.1).
- **Ventoy version strings pulled from the GitHub API are re-validated** against the same allowlist applied to user-supplied versions. Prevents a malformed upstream tag from being interpolated into a download URL unchecked.

### Known issues (carried over from v0.1.2)

- C2 (unauthenticated root helper) is closed by the XPC peer-check above. **C1** (hash-pin against a bundled-in-binary table) is still unresolved — the SHA-256 verification added in v0.1.2 defends against transport tampering but not against a compromised Ventoy repo. v0.2 target.
- GitHub Releases downloads of the Ventoy tarball can be slow (~30 s for 20 MB) on some network paths. Not a Mactoy bug, but the live progress bar now makes this visible instead of feeling like a hang.

## [0.1.2] — 2026-04-20

### Added

- Ko-fi support button in the bottom-left of the action bar (opens `ko-fi.com/cash508287` in the default browser).
- `.github/FUNDING.yml` wires up the GitHub "Sponsor" button at the top of the repo.
- `SECURITY.md` documents Mactoy's threat model and the v0.2 hardening roadmap.

### Security

- **SHA-256 verification of every Ventoy tarball** against the `sha256.txt` published with each Ventoy release. Cache reuse re-verifies on every install; mismatches abort and delete the cache. (C1 partial)
- **Whole-disk name regex.** `InstallPlan.validate` now rejects anything that isn't `^disk[0-9]+$`. Slice names (`disk2s1`), path-traversal (`../disk2`), and nonsense (`diskfoo`) can no longer reach `/dev/rdisk*`. (H1)
- **Raw-image driver re-probes the target disk in the helper.** `RawImageDriver` no longer trusts the `isExternal`/`isRemovable` booleans in the plan; it re-runs `diskutil info` inside the privileged helper and aborts on internal disks, matching what `VentoyDriver` already did. (H2)
- **Version-string allowlist before URL construction.** Any Ventoy version must match `[0-9]+(\.[0-9]+){1,3}`; injection/traversal attempts in a version string are rejected before URL templating. (H3)
- **Tar extraction uses `--no-same-owner --no-same-permissions`** and happens only after SHA-256 verification, blocking zip-slip and root-owned extracts. (M1)
- **Helper subprocesses run with a pinned minimal environment** (`PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `LC_ALL=C`). (L2)
- **Dropped unused `com.apple.security.automation.apple-events` entitlement** from the app. The `osascript` admin prompt is a local exec, not cross-app automation, so the entitlement was unused over-privilege. (M3)
- Added 5 tests (`VentoyDownloaderTests`, bsdName rejection cases in `InstallPlanTests`) covering the validation paths above. Total: 16/16 pass.

## [0.1.1] — 2026-04-20

Polish pass on the alpha UI. No disk-writing logic changed.

### Changed

- Custom app icon (Mactoy.icns) bundled into the app and DMG — previously the app shipped with a generic icon.
- "What this does" info panels now render as rounded rectangles. They were being drawn as capsules because `.glassEffect(.regular)` defaults to capsule shape around multi-line text.
- Flash Image panel now shows a red warning above the drop zone explaining that this mode creates a single-boot stick and pointing users at **Install Ventoy** if they actually want a multi-boot library.
- Install Ventoy version picker is now a dropdown populated from the last 20 stable Ventoy releases on GitHub. A **Custom…** option reveals a text field so pinning a specific tag still works if Mactoy ever stops shipping updates.

### Docs

- README now leads with a **Why Mactoy exists** section. Explains the Ventoy-has-no-macOS-installer gap, why the existing workarounds (LiveCD, VM, Python gist, balenaEtcher) don't cover it, and why the MAS sandbox rules out an App Store option.

### Build artifacts

- `Mactoy-0.1.1.dmg` is Developer ID signed (hardened runtime, timestamped) and Apple notarized.

## [0.1.0] — 2026-04-20

First alpha release.

### Added

- `Install Ventoy` mode: download + partition + boot-image write + exFAT format.
- `Flash Image` mode: raw `.iso` / `.img` / `.img.xz` / `.img.gz` writer.
- `Manage Disk` mode: list / add / remove ISOs on an existing Ventoy drive.
- Liquid Glass UI across sidebar, mode tabs, and action bar.
- `mactoyd` privileged helper CLI, invoked via osascript admin prompt.
- Unit tests cross-validating GPT math against the Python reference implementation.
- MIT license.

### Build artifacts

- `Mactoy-0.1.0.dmg` is Developer ID signed (hardened runtime, timestamped) and Apple notarized (submission `8fed8b49-fe5a-4138-b359-baf527fb520b`, ticket stapled).

### Known limitations

- macOS 26+ only.
- No cancel button mid-operation.
- Raw image flashing loads whole image into memory.
- Privileged helper invoked via `osascript` admin prompt (SMAppService daemon arrives in v0.2).
