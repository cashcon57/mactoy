# Contributing to Mactoy

Thanks for helping. Mactoy writes raw bytes to disks as root, so the bar for
changes is higher than usual in some places. This page explains where, and how
to get a pull request merged without a lot of back and forth.

## Before you start

- **Bugs:** open an issue first if you can. Include your macOS version,
  your Mactoy version, what you did, and what happened. For install or update
  failures, attach the output of:

  ```sh
  log show --predicate 'subsystem == "com.mactoy"' --last 1h
  ```

- **Features:** welcome. You don't need to ask first, just open a PR.
  If the change is large or reworks how something already works, an early
  issue or draft PR can save you time, but it's optional.
- **Small fixes** (typos, docs, an obvious one-line bug) are welcome too.
- **Security problems:** don't open a public issue. Follow
  [SECURITY.md](SECURITY.md).

## Building and testing

You need macOS 13.5 or newer and Xcode 16+ (Swift 6).

```sh
swift build
swift test
```

`swift test` needs no root, touches no real disks and makes no network
requests. Two tests are opt-in and skipped by default:
`MACTOY_REAL_VTOYEFI_IMG` (converts a real Ventoy EFI image) and
`MACTOY_NETWORK_TESTS` (downloads from GitHub). Their doc comments show how to
run them.

`./scripts/build-app.sh` builds `build/Mactoy.app` for running the UI.

### What your own build can and can't do

The privileged helper (`mactoyd`) only accepts connections from an app signed
with the maintainer's Developer ID. A build you make yourself will run and show
the UI, including disk detection and Manage Disk, but it **cannot** install,
update or flash a drive.

To exercise the install and update code, use the end-to-end harness in
[`scripts/e2e/`](scripts/e2e/README.md). It runs the real `VentoyDriver`
against a disk image, needs no root, and boots the result in QEMU under UEFI
and legacy BIOS.

## Pull requests

- **One change per PR.** A bug fix and a refactor are two PRs.
- **Branch from the latest `main`**, and rebase if `main` moves before review.
- **Tests:** new behaviour and bug fixes need tests. Put pure logic in
  `MactoyKit` so it can be tested without the UI. Tests use Swift Testing
  (`import Testing`).
- **Describe how you verified it.** Paste the `swift test` summary line, and
  say what you tried by hand (which macOS, which drive or disk image).
- **Screenshots** for any UI change.
- **Docs:** update `README.md` if you change something user-visible. Leave
  `CHANGELOG.md`, release notes and version numbers alone — the maintainer
  updates those when cutting a release.
- **Keep the minimum at macOS 13.5.** Newer APIs need an `#available` check
  and a fallback. The `LiquidGlass.swift` wrappers show the pattern.

### Code

- Match the style of the file you're in: naming, comment density, structure.
- Comments should explain *why*, not *what*. Link the issue number when a
  change exists because of a report (`// issue #7`).
- New third-party dependencies: call them out in the PR description and say
  why the standard library isn't enough.

### Matching Ventoy's behaviour

Mactoy must produce drives that behave exactly as if Ventoy's own tools had
made them. When your change touches how Ventoy reads the drive — the boot
files, `ventoy.json`, where images are found — check Ventoy's source or docs
and link what you relied on in the PR. "It works on my drive" isn't enough on
its own. Useful starting points:

- `INSTALL/tool/VentoyWorker.sh` and `ventoy_lib.sh` — what Ventoy2Disk writes
- `GRUB2/MOD_SRC/grub-2.04/grub-core/ventoy/` — what the boot menu reads
- <https://www.ventoy.net/en/plugin_entry.html> — plugin and `ventoy.json` docs

## Areas that get extra scrutiny

Changes to any of these are reviewed line by line and need tests that fail
without the change:

- `Sources/MactoyKit/VentoyDriver.swift`, `RawImageDriver.swift`,
  `DiskWriter.swift`, `GPT.swift`, `MBR.swift`, `VentoyLayout.swift`,
  `VentoyESP.swift`, `FAT16Reader.swift` — the bytes that get written.
- `Sources/mactoyd/` — the root helper and its client check.
- Disk selection and confirmation in `Sources/Mactoy/AppState.swift`. Mactoy
  has a six-layer defence against writing to the wrong disk (see the v0.3.1
  entry in `CHANGELOG.md`). Don't remove or weaken any layer, even if it looks
  redundant.

## AI-assisted contributions

These are welcome. Please say in the PR that you used an AI tool.

You're responsible for what you submit, however it was written. That means
testing it properly, not only checking that it compiles. You should be able to
explain what the change does and how you verified it: which tests cover it,
what you tried by hand, and what you checked it against.

## License

By contributing, you agree that your contribution is licensed under the
project's [MIT License](LICENSE).
