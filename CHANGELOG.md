# Changelog

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
