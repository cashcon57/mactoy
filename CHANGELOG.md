# Changelog

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
