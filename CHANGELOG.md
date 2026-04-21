# Changelog

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
