import Testing
@testable import MactoyKit

@Suite("Time Machine disks are hidden from the target list")
struct TimeMachineDiskFilterTests {
    /// Shape of `diskutil apfs list -plist`, trimmed to the keys we read.
    /// disk5 is a Time Machine container on USB disk4; disk3 is the boot
    /// disk; disk7 is an ordinary APFS USB stick.
    private let apfsList: [String: Any] = [
        "Containers": [
            [
                "ContainerReference": "disk3",
                "PhysicalStores": [["DeviceIdentifier": "disk0s2"]],
                "Volumes": [["DeviceIdentifier": "disk3s1", "Roles": ["System"]],
                            ["DeviceIdentifier": "disk3s5", "Roles": ["Data"]]],
            ],
            [
                "ContainerReference": "disk5",
                "PhysicalStores": [["DeviceIdentifier": "disk4s2"]],
                "Volumes": [["DeviceIdentifier": "disk5s1", "Roles": ["Backup"]]],
            ],
            [
                "ContainerReference": "disk8",
                "PhysicalStores": [["DeviceIdentifier": "disk7s2"]],
                "Volumes": [["DeviceIdentifier": "disk8s1", "Roles": [String]()]],
            ],
            [
                // Fusion-style backup container on two stores: hide both.
                "ContainerReference": "disk14",
                "PhysicalStores": [["DeviceIdentifier": "disk12s2"], ["DeviceIdentifier": "disk13s2"]],
                "Volumes": [["DeviceIdentifier": "disk14s1", "Roles": ["Backup"]]],
            ],
            [
                // A volume with no Roles key at all is not a backup.
                "ContainerReference": "disk16",
                "PhysicalStores": [["DeviceIdentifier": "disk15s2"]],
                "Volumes": [["DeviceIdentifier": "disk16s1"]],
            ],
        ]
    ]

    @Test("only disks holding a Backup-role volume are hidden, every store of one")
    func onlyBackupDiskHidden() {
        #expect(DiskInfo.timeMachineWholeDisks(apfsList: apfsList) == ["disk4", "disk12", "disk13"])
    }

    @Test("no APFS output hides nothing")
    func emptyHidesNothing() {
        #expect(DiskInfo.timeMachineWholeDisks(apfsList: [:]).isEmpty)
    }

    @Test("partition names map to their whole disk")
    func wholeDisk() {
        #expect(DiskInfo.wholeDisk(of: "disk4s2") == "disk4")
        #expect(DiskInfo.wholeDisk(of: "disk12s10") == "disk12")
        #expect(DiskInfo.wholeDisk(of: "disk6") == "disk6")
    }

    @Test("a Sidecar-role (Time Machine) container is treated as a backup too")
    func sidecarRole() {
        let list: [String: Any] = ["Containers": [[
            "ContainerReference": "disk21",
            "PhysicalStores": [["DeviceIdentifier": "disk20s2"]],
            "Volumes": [["DeviceIdentifier": "disk21s1", "Roles": ["Sidecar"]]],
        ]]]
        #expect(DiskInfo.timeMachineWholeDisks(apfsList: list) == ["disk20"])
    }
}
