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
        ]
    ]

    @Test("only the disk holding a Backup-role volume is hidden")
    func onlyBackupDiskHidden() {
        #expect(DiskInfo.timeMachineWholeDisks(apfsList: apfsList) == ["disk4"])
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
}
