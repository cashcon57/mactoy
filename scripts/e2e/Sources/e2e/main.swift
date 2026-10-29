import Foundation
import MactoyKit

// usage: e2e <diskN> <install|update> <secure:on|off> [mbr|gpt] [version]
//        e2e <diskN> flash <image> [sha256|-] [noverify]
//        MACTOY_E2E_CANCEL_AFTER=<seconds> presses Cancel that long into the run.
//        e2e scan <mounted Ventoy volume>
// Runs the REAL VentoyDriver against an hdiutil-attached disk image.
struct Sink: ProgressSink {
    func report(_ u: ProgressUpdate) {
        if u.bytesDone == nil || u.bytesDone == u.bytesTotal { print("  [\(u.phase)] \(u.message)") }
    }
}
let a = CommandLine.arguments

// MACTOY_E2E_CANCEL_AFTER=<seconds>: press Cancel that long into the run (#21).
let control = RunControl()
if let after = ProcessInfo.processInfo.environment["MACTOY_E2E_CANCEL_AFTER"].flatMap(Double.init) {
    Task.detached {
        try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
        print("  [e2e] cancel requested: accepted=\(control.requestCancel())")
    }
}

// e2e scan <mounted Ventoy volume> — print what Manage Disk will list.
if a.count == 3, a[1] == "scan" {
    let result = VentoyImageLibrary.scan(volume: URL(fileURLWithPath: a[2]))
    print("folder: \(result.directory.path)")
    for url in result.images { print("image: \(url.path)") }
    exit(0)
}
// e2e <diskN> flash <image> [sha256|-] [noverify] — the REAL RawImageDriver (#20, #26).
if a.count >= 4, a[2] == "flash" {
    let bsd = a[1]
    let target = try DiskInfo.probe(bsdName: bsd)
    guard target.mediaName == "Disk Image" else { fatalError("refusing: \(bsd) is not a disk image (\(target.mediaName ?? "nil"))") }
    let checksum = a.count > 4 && a[4] != "-" ? a[4] : nil
    let plan = InstallPlan(driver: .rawImage, target: target, source: .localImage(path: a[3]), workDir: "/unused",
                           partitionStyle: .mbr, expectedImageSHA256: checksum,
                           verifyAfterWriting: !(a.count > 5 && a[5] == "noverify"))
    do {
        try await RawImageDriver(control: control).execute(plan: plan, progress: Sink())
        print("RESULT ok")
    } catch {
        print("RESULT FAILED: \(error)"); exit(1)
    }
    exit(0)
}

let bsd = a[1], op = a[2], secure = a[3] == "on"
// Default matches the app's: MBR.
guard let style = VentoyPartitionStyle(rawValue: a.count > 4 ? a[4] : "mbr") else {
    fatalError("partition style must be mbr or gpt, got \(a[4])")
}
let version = a.count > 5 ? a[5] : "1.1.17"
let target = try DiskInfo.probe(bsdName: bsd)
guard target.mediaName == "Disk Image" else { fatalError("refusing: \(bsd) is not a disk image (\(target.mediaName ?? "nil"))") }
let plan = InstallPlan(driver: .ventoy, target: target, source: .ventoyVersion(version),
                       workDir: "/unused", ventoyOperation: op == "update" ? .updateInPlace : .freshInstall,
                       secureBoot: secure, partitionStyle: style)
do {
    try await VentoyDriver(control: control).execute(plan: plan, progress: Sink())
    let p = VentoyVersionProbe.probe(bsdName: bsd)
    print("RESULT ok: isVentoy=\(p.isVentoyDisk) version=\(p.detectedVersion ?? "-") style=\(p.partitionStyle) secureBoot=\(p.secureBootEnabled)")
} catch {
    print("RESULT FAILED: \(error)"); exit(1)
}
