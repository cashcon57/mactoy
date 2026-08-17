import Foundation

/// Curated list of USB bridges / enclosures known to misbehave during
/// sustained raw disk writes on macOS. Match is done against
/// `DiskTarget.mediaName` (returned by `diskutil info`) via
/// case-insensitive substring lookup — no IOKit VID/PID plumbing
/// required.
///
/// This is a **warning**, not a block: the pre-flight banner lets the
/// user proceed if they want to. The Install / Update Ventoy panels
/// surface the banner when the selected disk's `mediaName` matches an
/// entry here.
///
/// Contributions welcome — open a PR adding an entry with:
///   1. A substring that uniquely identifies the bridge in diskutil
///      output.
///   2. A short one-sentence symptom description.
///   3. The suggested workaround (usually: force USB 2.0 to disable
///      UAS and fall back to Bulk-Only Transport).
///   4. Ideally a link to an issue with unified-log evidence.
public struct QuirkyEnclosure: Sendable {
    public let mediaNameSubstring: String
    public let symptom: String
    public let workaround: String
    public let referenceURL: String?

    public init(mediaNameSubstring: String, symptom: String, workaround: String, referenceURL: String? = nil) {
        self.mediaNameSubstring = mediaNameSubstring
        self.symptom = symptom
        self.workaround = workaround
        self.referenceURL = referenceURL
    }
}

public enum QuirkyEnclosureRegistry {

    /// Seeded from user-reported issues on the Mactoy tracker.
    /// **Keep entries specific.** A too-broad substring
    /// (e.g. "USB") would false-positive on innocent drives.
    public static let known: [QuirkyEnclosure] = [
        QuirkyEnclosure(
            mediaNameSubstring: "RTL9210",
            symptom: "The RTL9210 / RTL9210B Realtek USB-NVMe/SATA bridge is known to stall its UAS stream endpoints under sustained raw writes on Apple silicon Macs, forcing macOS to reset the XHCI controller and killing the write mid-flight.",
            workaround: "Connect the drive with a USB 2.0-only cable or port (forces slower Bulk-Only Transport instead of UAS). Slower, but reliable.",
            referenceURL: "https://github.com/cashcon57/mactoy/issues/4"
        )
    ]

    /// Returns the first matching quirky-enclosure entry for the given
    /// `mediaName`, or nil if none match. Case-insensitive substring
    /// match. Empty / nil mediaName returns nil.
    public static func lookup(mediaName: String?) -> QuirkyEnclosure? {
        guard let name = mediaName, !name.isEmpty else { return nil }
        let upper = name.uppercased()
        return known.first { upper.contains($0.mediaNameSubstring.uppercased()) }
    }
}
