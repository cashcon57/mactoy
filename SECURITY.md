# Security

Mactoy writes raw bytes to an external block device and runs part of its
pipeline as `root`. Before trusting an alpha build, know the constraints
below.

## Threat model (what Mactoy defends against)

- **MITM and corrupted downloads of the Ventoy tarball.** Every Ventoy
  archive is SHA-256-verified against `sha256.txt` published alongside
  the release before the bytes are written to disk as root. Cache reuse
  re-verifies on every install. A mismatch aborts the install and
  deletes the cached file. (see `Sources/MactoyKit/VentoyDownloader.swift`)
- **Crafted install plans targeting internal disks.** The helper
  re-probes the target BSD device via `diskutil` and rejects anything
  that is not external or removable, regardless of what the plan JSON
  claims. Whole-disk names are also regex-restricted to
  `disk[0-9]+` — slice names (`disk2s1`) and path-traversal
  (`../disk2`) are rejected before any `/dev/rdisk*` open.
- **Shell / URL injection via version strings.** Any version string fed
  into the download URL template must match `[0-9]+(\.[0-9]+){1,4}`;
  newlines, `&&`, `../`, etc. are rejected before URL construction.
- **Tarball zip-slip and root-owned extracts.** Extraction uses
  `--no-same-owner --no-same-permissions`, combined with SHA-256
  verification of the archive before extraction.
- **Tampered app binary.** The app and helper are signed with a
  Developer ID certificate, hardened-runtime-enabled, and Apple-notarized.
- **Subprocess environment leakage.** The helper pins a minimal PATH
  and locale when spawning `diskutil` / `tar` / `newfs_exfat`.

## Known limitations (v0.1 alpha)

These are **not yet defended against** and are explicitly on the v0.2
roadmap. If your threat model requires any of them, do not use Mactoy
until a release that addresses them.

- **Unauthenticated root helper (critical).** `mactoyd` runs as root
  when invoked via the `osascript` admin prompt, and trusts the
  identity of the caller only insofar as they could produce an admin
  password. There is no SMAppService / XPC peer audit-token check.
  Any process with admin rights or a second privilege-escalation bug
  on the same machine can pipe a JSON plan into `mactoyd` and get a
  raw write to any re-probed external disk. **Planned fix:** migrate
  the helper to an `SMAppService`-installed privileged daemon with a
  code-signature + designated-requirement check on the connecting
  client.
- **Same-origin trust in SHA-256 verification.** The expected hash is
  fetched from the same GitHub release as the tarball. This defends
  against transport-level tampering but does not defend against a
  compromised `ventoy/Ventoy` repo. **Planned fix:** ship a
  bundled-in-binary hash table for known Ventoy versions and warn
  loudly on any version not in the table.
- **No post-unmount identity re-binding (TOCTOU).** The helper
  re-probes the target disk's properties, but does not pin an
  immutable identifier (IOKit registry-entry ID, pre-unmount volume
  UUID) across the `unmount → open → write` sequence. Plugging and
  unplugging USB devices mid-install could cause a BSD name reuse
  race. **Planned fix:** capture an immutable identifier in the plan
  and re-verify post-unmount.
- **In-memory raw-image flashing.** `RawImageDriver` currently loads
  the full image into RAM before writing. A 6 GB ISO on an 8 GB Mac
  will thrash. **Planned fix:** stream-decompress + chunked write.
- **No cancel button mid-operation.** Once you click Install, the
  only way to abort is quitting the app or ejecting the USB, either
  of which leaves the disk partially written.

## Reporting a vulnerability

Open a GitHub issue at <https://github.com/cashcon57/mactoy/issues>
with the label `security`, or — if the issue is sensitive — email
`cashcon57@gmail.com` with subject `[mactoy-security]`.

There is no bug bounty. You will be credited in the release notes of
the first version that includes a fix unless you request otherwise.
