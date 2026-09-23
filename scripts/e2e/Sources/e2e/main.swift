import Foundation
import MactoyKit

// usage: e2e <diskN> <install|update> <secure:on|off> [version]
// Runs the REAL VentoyDriver against an hdiutil-attached disk image.
struct Sink: ProgressSink {
    func report(_ u: ProgressUpdate) {
        if u.bytesDone == nil || u.bytesDone == u.bytesTotal { print("  [\(u.phase)] \(u.message)") }
    }
}
let a = CommandLine.arguments
let bsd = a[1], op = a[2], secure = a[3] == "on", version = a.count > 4 ? a[4] : "1.1.17"
let target = try DiskInfo.probe(bsdName: bsd)
guard target.mediaName == "Disk Image" else { fatalError("refusing: \(bsd) is not a disk image (\(target.mediaName ?? "nil"))") }
let plan = InstallPlan(driver: .ventoy, target: target, source: .ventoyVersion(version),
                       workDir: "/unused", ventoyOperation: op == "update" ? .updateInPlace : .freshInstall,
                       secureBoot: secure)
do {
    try await VentoyDriver().execute(plan: plan, progress: Sink())
    let p = VentoyVersionProbe.probe(bsdName: bsd)
    print("RESULT ok: isVentoy=\(p.isVentoyDisk) version=\(p.detectedVersion ?? "-") style=\(p.partitionStyle) secureBoot=\(p.secureBootEnabled)")
} catch {
    print("RESULT FAILED: \(error)"); exit(1)
}
