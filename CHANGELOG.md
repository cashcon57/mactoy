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

### Known limitations
- Ad-hoc signed (not Developer ID). Gatekeeper requires right-click → Open on first launch.
- Not yet notarized.
- macOS 26+ only.
- No cancel button mid-operation.
- Raw image flashing loads whole image into memory.
