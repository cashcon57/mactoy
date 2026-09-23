# End-to-end boot test without a USB stick

Runs the real `VentoyDriver` against a disk image, then boots that image in
QEMU under UEFI (OVMF) and legacy BIOS (SeaBIOS) and screenshots the result.

Why this works: a raw image attached with `hdiutil` shows up as a removable
whole disk whose `/dev/rdiskN` is owned by you, so the driver's validation
passes and no root is needed. Nothing here can open a physical disk — those
need root — and the harness refuses any target whose media name isn't
`Disk Image`.

Needs `brew install qemu`.

```sh
cd scripts/e2e && swift build

# 1. A blank 1 GiB "stick"
mkfile -n 1g stick.img
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage stick.img | awk 'NR==1{print $1}')

# 2. Real install.  usage: e2e <diskN> <install|update> <on|off> [ventoy-version]
.build/debug/e2e "${DEV#/dev/}" install off

# 3. Optionally copy an ISO onto the mounted "Ventoy" volume, then:
hdiutil detach "$DEV"

# 4. Boot it.  usage: qemu-drive.py <img> <uefi|bios> <screenshot-prefix> <steps…>
#    steps: wait:<seconds>  key:<qemu key name>  shot:<label>
python3 qemu-drive.py stick.img uefi shot wait:60 shot:menu
python3 qemu-drive.py stick.img bios shot wait:45 shot:menu
```

`shot-menu.png` should show the Ventoy menu with `<version> UEFI` or
`<version> BIOS` bottom-left. The guest's serial console is written to
`<prefix>-serial.log`. QEMU runs with `-snapshot`, so booting never modifies
the image.

To test Update Ventoy, re-attach the image and run `e2e <diskN> update <on|off>`.
An MBR-style stick (what Ventoy2Disk creates by default, and what Mactoy never
creates itself) has to be built by hand: `boot.img[0..<446]` + an MBR with
partition 1 at LBA 2048 (type 0x07, active) and a 65536-sector partition 2
(type 0xEF) at the end, `core.img` at LBA 1, `ventoy.disk.img` at partition 2.

What this can't tell you: how a particular machine's firmware behaves. OVMF is
a spec-compliant UEFI; it isn't Apple's EFI 1.10 or a vendor BIOS with quirks.
