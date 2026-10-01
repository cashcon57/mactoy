import Foundation
import MactoyKit

// usage: e2e <diskN> <install|update> <secure:on|off> [mbr|gpt] [version]
//        e2e scan <mounted Ventoy volume>
// Runs the REAL VentoyDriver against an hdiutil-attached disk image.
struct Sink: ProgressSink {
    func report(_ u: ProgressUpdate) {
        if u.bytesDone == nil || u.bytesDone == u.bytesTotal { print("  [\(u.phase)] \(u.message)") }
    }
}
let a = CommandLine.arguments

// e2e scan <mounted Ventoy volume> — print what Manage Disk will list.
if a.count == 3, a[1] == "scan" {
    let result = VentoyImageLibrary.scan(volume: URL(fileURLWithPath: a[2]))
    print("folder: \(result.directory.path)")
    for url in result.images { print("image: \(url.path)") }
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
    try await VentoyDriver().execute(plan: plan, progress: Sink())
    let p = VentoyVersionProbe.probe(bsdName: bsd)
    print("RESULT ok: isVentoy=\(p.isVentoyDisk) version=\(p.detectedVersion ?? "-") style=\(p.partitionStyle) secureBoot=\(p.secureBootEnabled)")
} catch {
    print("RESULT FAILED: \(error)"); exit(1)
}
