# Security

Mactoy writes raw bytes to an external block device, and part of its
pipeline runs as `root`. This page lists what it defends against and
what it doesn't yet, so you can decide whether it fits your threat
model.

## What Mactoy needs

- **A root helper.** Writing to `/dev/rdisk*` needs root, so the
  helper, `mactoyd`, is a `launchd` daemon registered with
  `SMAppService` after you approve it in System Settings.
- **Full Disk Access.** macOS blocks raw disk access, even for root,
  unless the responsible app has Full Disk Access. You grant it to
  Mactoy once, and the helper inherits it.
- **No App Sandbox.** The sandbox forbids raw block-device access, so
  Mactoy is distributed as a Developer ID app, not through the App
  Store.

## Threat model (what Mactoy defends against)

- **Other processes driving the root helper.** On every XPC connection
  the helper reads the caller's audit token and checks its code
  signature against the requirement `anchor apple generic`, Mactoy's
  team identifier and the bundle identifier `com.mactoy.Mactoy`. Any
  other process, even one running as root, is refused before it can
  send a request. The helper also refuses to start unless it is
  running as root. (see `Sources/mactoyd/main.swift`)
- **The helper staying around.** `launchd` starts the helper when Mactoy
  connects, and it exits about half a second after the last connection
  closes. The approval sheet has a **Remove the helper when done** box,
  ticked by default, that unregisters the helper after the next
  install, update or flash. If you untick it, the helper stays
  registered until you turn it off in System Settings > General >
  Login Items.
- **Crafted install plans targeting internal disks.** The helper
  refuses a plan unless its target is a whole disk (`disk` followed by
  a number, never a slice like `disk2s1` or a path like `../disk2`),
  isn't `disk0` or `disk1`, and is external or removable. Before
  writing, it re-probes the disk with `diskutil` itself and aborts if
  the live disk's flags, size or name don't match the plan.
- **Writing to the wrong disk.** The disk you confirm is captured with
  its fingerprint (BSD name, size, external and removable flags, media
  name), and the disk list can't change the target while the
  confirmation is open. The fingerprint is checked again before the
  first unmount and before the raw writes begin, including after a
  long download or decompression. A mismatch aborts before anything is
  written. (See the limitations below for what the fingerprint can't
  catch.)
- **Erasing Time Machine backups.** Drives with an APFS Time Machine
  volume are listed but locked. Install, update and flash refuse them
  unless you unlock that drive for the session. The check runs again
  when a run starts, so a backup volume that appeared since the last
  refresh is still caught.
- **MITM and corrupted downloads of the Ventoy tarball.** Every Ventoy
  archive is SHA-256-verified against the `sha256.txt` published with
  the release before anything is extracted or written to your drive. A
  freshly downloaded archive that doesn't match is deleted and the
  install aborts. A cached archive is re-verified on every install, and
  one that doesn't match is deleted and downloaded again.
  (see `Sources/MactoyKit/VentoyDownloader.swift`)
- **Shell and URL injection via version strings.** A version string
  used in the download URL must be numbers separated by dots (two to
  four parts, at most 32 characters); newlines, `&&`, `../` and the like
  are rejected before the URL is built.
- **Malicious paths and owners in the Ventoy archive.** The archive is
  extracted with `/usr/bin/tar`, which by default refuses absolute
  paths and `..` components. `--no-same-owner --no-same-permissions`
  stops it from creating root-owned or privileged files from the
  archive's metadata.
- **Malicious boot themes.**
  - Each theme in the catalog is pinned to one exact download by
    SHA-256, and downloads are only accepted from github.com,
    codeload.github.com, gitlab.com and codeberg.org.
  - Only `.txt`, `.png`, `.jpg`, `.jpeg`, `.tga` and `.pf2` files are
    copied from a theme, never `.cfg` files, which Ventoy would run as
    boot scripts.
  - A `.zip` you import yourself has its file list checked with
    `zipinfo` before it's unpacked by `ditto` in a separate process.
  - On the drive, Mactoy changes only the `theme` setting in
    `ventoy.json` and keeps a copy of the original as
    `ventoy.json.mactoy-backup`. It never writes through links. It only
    deletes theme folders it created (marked with a `mactoy-` prefix
    and a marker file), its own leftover staging folders, the `._`
    files macOS adds next to them on exFAT, and the `ventoy/themes`
    folder if that leaves it empty.
  - Themes are written by the app, not the root helper.
- **Tampered app binary.** The app and helper are signed with a
  Developer ID certificate, use the hardened runtime, and are notarized
  by Apple.
- **Subprocess environment leakage.** Commands such as `diskutil`,
  `tar` and `newfs_exfat` are run by absolute path with a fixed `PATH`
  and the `C` locale, so they don't inherit the user's environment
  when running as root.

## Known limitations

These are not defended against yet. If your threat model depends on
any of them, take that into account before using Mactoy.

- **Same-origin trust in the Ventoy checksum.** The expected SHA-256 is
  fetched from the same GitHub release as the tarball. This catches
  transport tampering and corruption, but not a compromised
  `ventoy/Ventoy` release. **Planned fix:** a hash table for known
  Ventoy versions built into the app, with a clear warning for any
  version not in it.
- **The disk fingerprint isn't a hardware identity.** The fingerprint
  is taken when you confirm, and compares the BSD name, size, flags and
  media name, not an immutable identifier such as the IOKit registry
  entry ID. If you swap in an identical drive (same model and size)
  that macOS gives the same `/dev/disk<N>` name at any point after
  confirming, Mactoy won't notice. The window is longest when flashing
  a compressed image, during decompression. **Planned fix:** pin an
  immutable identifier in the plan.
- **The final format step isn't re-checked.** On a fresh install, after
  the partition table and bootloader are written, Mactoy waits for macOS
  to detect the new partitions (up to 90 seconds) and formats the first
  one as exFAT without checking the fingerprint again. **Planned fix:**
  re-check before formatting.
- **Disk-name and version checks accept non-ASCII numerals.** They use
  Swift's `isNumber`, which also accepts digits from other scripts, so
  they don't strictly enforce `[0-9]`. The read-only Ventoy version
  probe also opens the named disk without these checks. Only the
  signed Mactoy app can send either request to the helper. **Planned
  fix:** require ASCII digits and validate the probe's disk name.
- **Compressed images are decompressed in memory.** Plain `.iso` and
  `.img` files are memory-mapped where macOS allows it and written in
  4 MB chunks. `.img.xz` and `.img.gz` files are read and decompressed
  fully into RAM before writing, so a large compressed image can
  exhaust memory on a Mac with little RAM. **Planned fix:** decompress
  while writing.
- **No cancel button.** Once you confirm an install, update or flash,
  there's no way to cancel it in the app, including during the download
  or decompression. Quitting Mactoy stops the helper about half a
  second later: before the first write, the drive is left untouched;
  during writing, it's left partly written.
- **Time Machine detection is APFS only.** Older Time Machine drives
  formatted as Mac OS Extended (HFS+) aren't recognised or locked.
- **The theme catalog is trusted from this repository.** Mactoy fetches
  `themes/catalog.json` from `main`. Someone able to change `main` could
  point a theme at a different download with a matching checksum. The
  file filter above still applies to whatever is downloaded.
- **Imported zip files are bounded by time, not size.** A `.zip` you
  import yourself that misreports its sizes is stopped by a 60-second
  limit on unpacking rather than a size limit.
- **A refused caller can still start the helper.** `launchd` starts the
  helper for any connection attempt. A refused caller gets nothing from
  it, but the helper stays running until Mactoy next connects and
  disconnects.
- **The helper's caller check pins the team, not the certificate
  type.** It accepts any Apple-issued certificate for Mactoy's team
  with Mactoy's bundle identifier, not only the Developer ID
  certificate.
- **The Ventoy cache outlives the helper.** Downloaded Ventoy archives
  stay in `/Library/Application Support/Mactoy/Cache` after the helper
  is removed. Delete that folder if you remove Mactoy.

## What Mactoy connects to

- **api.github.com**, when it starts, for the list of Ventoy releases.
- **github.com**, from the helper, to download the Ventoy release you
  install and its `sha256.txt`.
- **raw.githubusercontent.com**, for the theme list and theme previews
  from this repository, when Mactoy starts and when you open the theme
  picker if the list hasn't loaded yet.
- **The theme's host** (see the list above), when you choose a theme
  that isn't already downloaded.

Nothing about you or your drives is sent. As with any web request, the
servers see your IP address, and Mactoy identifies itself with the
User-Agent `Mactoy`.

## Reporting a vulnerability

Open a GitHub issue at <https://github.com/cashcon57/mactoy/issues>
with the label `security`. If the issue is sensitive, email
`cashcon57@gmail.com` with the subject `[mactoy-security]` instead.

There is no bug bounty. You will be credited in the release notes of
the first version that includes a fix unless you request otherwise.
