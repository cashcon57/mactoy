# Changelog

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
