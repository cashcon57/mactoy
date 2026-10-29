import Foundation
import Testing
@testable import MactoyKit

/// What Mactoy reads from macOS about a drive, for each kind of drive people plug in, without
/// needing the drive. The parts of Mactoy that touch a drive's hardware identity are the
/// `diskutil info` output and the IORegistry tree above the disk; everything after that is
/// the same code path the disk-image tests run end to end.
///
/// Key names are the ones `diskutil info -plist` prints on macOS 26 (checked against this Mac's
/// internal SSD and an attached disk image). Values follow what each kind of drive reports.
@Suite("Kinds of drive")
struct DriveKindsTests {

    // MARK: - diskutil info

    nonisolated(unsafe) static let usbStick: [String: Any] = [
        "BusProtocol": "USB", "Internal": false, "Removable": true, "RemovableMedia": true,
        "Ejectable": true, "MediaName": "SanDisk Ultra", "TotalSize": 61_530_439_680,
        "VirtualOrPhysical": "Physical", "DeviceBlockSize": 512,
    ]
    nonisolated(unsafe) static let usbSSD: [String: Any] = [
        "BusProtocol": "USB", "Internal": false, "Removable": false, "RemovableMedia": false,
        "Ejectable": true, "MediaName": "Samsung PSSD T7 Media", "TotalSize": 1_000_204_886_016,
        "VirtualOrPhysical": "Physical", "DeviceBlockSize": 512,
    ]
    nonisolated(unsafe) static let thunderboltSSD: [String: Any] = [
        "BusProtocol": "PCI-Express", "Internal": false, "Removable": false, "RemovableMedia": false,
        "Ejectable": true, "MediaName": "Samsung SSD 990 PRO 2TB", "TotalSize": 2_000_398_934_016,
        "VirtualOrPhysical": "Physical", "DeviceBlockSize": 512,
    ]
    /// A card in a Mac's built-in SD slot: internal bus, removable media.
    nonisolated(unsafe) static let builtInSDCard: [String: Any] = [
        "BusProtocol": "Secure Digital", "Internal": true, "Removable": true, "RemovableMedia": true,
        "Ejectable": true, "MediaName": "SD Card Reader", "TotalSize": 63_864_569_856,
        "VirtualOrPhysical": "Physical", "DeviceBlockSize": 512,
    ]
    /// This Mac's own SSD, as diskutil printed it.
    nonisolated(unsafe) static let internalSSD: [String: Any] = [
        "BusProtocol": "Apple Fabric", "Internal": true, "Removable": false, "RemovableMedia": false,
        "Ejectable": false, "MediaName": "APPLE SSD AP1024Z", "TotalSize": 1_000_555_581_440,
        "VirtualOrPhysical": "Physical", "DeviceBlockSize": 4096,
    ]
    /// An hdiutil-attached raw image, as diskutil printed it: what the end-to-end tests write to.
    nonisolated(unsafe) static let diskImage: [String: Any] = [
        "BusProtocol": "Disk Image", "Internal": false, "Removable": true, "RemovableMedia": true,
        "Ejectable": true, "MediaName": "Disk Image", "TotalSize": 629_145_600,
        "VirtualOrPhysical": "Virtual", "DeviceBlockSize": 512,
    ]

    private func target(_ info: [String: Any], serial: String? = nil) -> DiskTarget {
        DiskInfo.target(bsdName: "disk4", info: info, volumes: [], serialNumber: serial)
    }

    private func plan(_ t: DiskTarget) -> InstallPlan {
        InstallPlan(driver: .ventoy, target: t, source: .ventoyVersion("1.1.17"), workDir: "/tmp",
                    partitionStyle: t.sizeInBytes > 2_199_023_255_552 ? .gpt : .mbr)
    }

    @Test("USB sticks, USB and Thunderbolt SSDs, SD cards and disk images are writable; the Mac's own SSD isn't")
    func whatIsWritable() throws {
        for (name, info) in [("USB stick", Self.usbStick), ("USB SSD", Self.usbSSD), ("Thunderbolt SSD", Self.thunderboltSSD),
                             ("SD card", Self.builtInSDCard), ("disk image", Self.diskImage)] {
            #expect(throws: Never.self, "\(name)") { try plan(target(info)).validate() }
        }
        #expect(throws: PlanValidationError.self) { try plan(target(Self.internalSSD)).validate() }
    }

    @Test("external and removable flags come from the keys diskutil actually prints")
    func flags() {
        let stick = target(Self.usbStick)
        #expect(stick.isExternal && stick.isRemovable)
        #expect(stick.sizeInBytes == 61_530_439_680)
        #expect(stick.mediaName == "SanDisk Ultra")

        let ssd = target(Self.usbSSD)
        #expect(ssd.isExternal, "a USB SSD isn't removable media, but it's external")
        #expect(ssd.isRemovable, "and ejectable")

        let sd = target(Self.builtInSDCard)
        #expect(!sd.isExternal)
        #expect(sd.isRemovable, "the built-in slot is internal, but the card is removable")

        let mac = target(Self.internalSSD)
        #expect(!mac.isExternal && !mac.isRemovable)
    }

    @Test("an external drive that's neither removable nor ejectable is still writable, now that external is read")
    func externalOnly() throws {
        var info = Self.thunderboltSSD
        info["Ejectable"] = false
        let t = target(info)
        #expect(t.isExternal && !t.isRemovable)
        try plan(t).validate()
    }

    @Test("an older macOS spelling of the internal flag is understood too")
    func olderKey() {
        var info = Self.usbStick
        info.removeValue(forKey: "Internal")
        info["DeviceInternal"] = false
        #expect(target(info).isExternal)
    }

    @Test("missing keys are read as the safe answer: not external, not removable")
    func missingKeys() {
        let t = target(["TotalSize": 61_530_439_680])
        #expect(!t.isExternal && !t.isRemovable)
        #expect(throws: PlanValidationError.self) { try plan(t).validate() }
    }

    @Test("the app's and the helper's reads of the same drive have the same fingerprint")
    func sameFingerprint() {
        for info in [Self.usbStick, Self.usbSSD, Self.thunderboltSSD, Self.builtInSDCard, Self.diskImage] {
            #expect(target(info, serial: "S1").fingerprintMismatch(against: target(info, serial: "S1")) == nil)
        }
    }

    // MARK: - IORegistry: where the serial number comes from

    /// A node in a made-up registry tree, child first.
    final class Node: RegistryNode {
        let classes: Set<String>
        let properties: [String: Any]
        var up: Node?
        init(_ classes: [String], _ properties: [String: Any] = [:]) {
            self.classes = Set(classes)
            self.properties = properties
        }
        func conforms(to className: String) -> Bool { classes.contains(className) }
        func property(_ key: String) -> Any? { properties[key] }
        func parent() -> (any RegistryNode)? { up }
    }

    /// Links nodes child to parent and returns the bottom one (the disk's IOMedia).
    private func chain(_ nodes: [Node]) -> Node {
        for (child, parent) in zip(nodes, nodes.dropFirst()) { child.up = parent }
        return nodes[0]
    }

    private func media() -> Node { Node(["IOMedia"]) }
    private func driver() -> Node { Node(["IOBlockStorageDriver"]) }
    private func storage(serial: String?) -> Node {
        Node(["IOBlockStorageServices", "IOBlockStorageDevice"],
             ["Device Characteristics": serial.map { ["Product Name": "Ultra", "Serial Number": $0] } ?? ["Product Name": "Ultra"]])
    }
    private func usbDevice(serial: String?) -> Node {
        Node(["IOUSBHostDevice"], serial.map { ["USB Serial Number": $0] } ?? [:])
    }
    private func hub(serial: String) -> Node { Node(["IOUSBHostDevice", "AppleUSBHub"], ["USB Serial Number": serial]) }

    /// A USB stick (UAS or BOT) behind a hub, as macOS builds it.
    private func usbStick(storageSerial: String?, usbSerial: String?, hubSerial: String = "HUB-0001") -> Node {
        chain([media(), driver(), storage(serial: storageSerial),
               Node(["IOSCSIPeripheralDeviceType00"]), Node(["IOSCSILogicalUnitNub"]),
               Node(["IOUSBMassStorageUASDriver"]), Node(["IOUSBHostInterface"]),
               usbDevice(serial: usbSerial), Node(["AppleUSB30HubPort"]), hub(serial: hubSerial), Node(["AppleT8112USBXHCI"])])
    }

    @Test("a USB stick's serial is its own, from the storage device")
    func stickSerial() {
        #expect(DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: "4C530001230615117405", usbSerial: "4C530001230615117405")) == "4C530001230615117405")
    }

    @Test("a stick whose storage device has no serial gets the USB device's")
    func stickSerialFromUSB() {
        #expect(DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: nil, usbSerial: "AA00000000012345")) == "AA00000000012345")
    }

    @Test("a placeholder storage serial falls through to the USB device's")
    func placeholderFallsThrough() {
        #expect(DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: "000000000000", usbSerial: "AA00000000012345")) == "AA00000000012345")
    }

    @Test("a stick with no serial at all gets none, never its hub's")
    func neverTheHub() {
        #expect(DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: nil, usbSerial: nil, hubSerial: "HUB-0001")) == nil)
    }

    @Test("the same stick on another port, or behind another hub, keeps its serial")
    func portIndependent() {
        let a = DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: nil, usbSerial: "AA01", hubSerial: "HUB-A"))
        let b = DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: nil, usbSerial: "AA01", hubSerial: "HUB-B"))
        #expect(a == "AA01" && a == b)
    }

    @Test("a Thunderbolt NVMe drive's serial comes from its NVMe controller")
    func thunderboltSerial() {
        let tree = chain([media(), driver(),
                          Node(["IONVMeBlockStorageDevice", "IOBlockStorageDevice"], ["Device Characteristics": ["Serial Number": "S6B0NL0W123456A"]]),
                          Node(["IONVMeController"]), Node(["IOPCIDevice"]), Node(["IOThunderboltPort"])])
        #expect(DiskInfo.serialNumber(walkingUpFrom: tree) == "S6B0NL0W123456A")
    }

    @Test("an SD card in a USB reader gets the reader's serial, the documented limit")
    func cardReader() {
        #expect(DiskInfo.serialNumber(walkingUpFrom: usbStick(storageSerial: "000000000820", usbSerial: "000000000820")) == "000000000820")
    }

    @Test("a raw disk image has no serial")
    func diskImageNoSerial() {
        let tree = chain([media(), driver(), Node(["IOHDIXHDDriveOutKernel", "IOBlockStorageDevice"], ["Device Characteristics": [:] as [String: Any]]),
                          Node(["IOHDIXController"]), Node(["IOResources"])])
        #expect(DiskInfo.serialNumber(walkingUpFrom: tree) == nil)
    }

    @Test("a registry that never ends is given up on")
    func endlessTree() {
        let loop = Node(["IOService"])
        loop.up = loop
        #expect(DiskInfo.serialNumber(walkingUpFrom: loop) == nil)
    }

    @Test("this Mac's internal disk still reads through the real IORegistry", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func liveRegistry() {
        #expect(DiskInfo.serialNumber(bsdName: "disk0") != nil)
    }
}
