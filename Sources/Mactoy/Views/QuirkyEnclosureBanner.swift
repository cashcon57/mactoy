import SwiftUI
import MactoyKit

/// Pre-flight warning banner shown when the selected disk's mediaName
/// matches a known-quirky USB enclosure entry in
/// `QuirkyEnclosureRegistry`. See issue #4 for the RTL9210B seed case
/// and the full user-provided XHCI stall forensics.
///
/// This is a non-blocking warning — the user can proceed with install
/// or update. The purpose is to save the user the "ENXIO mid-write →
/// re-plug → try again on a different port" discovery loop by pointing
/// them at the known workaround before the write starts.
struct QuirkyEnclosureBanner: View {
    let quirk: QuirkyEnclosure
    let mediaName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Known-quirky enclosure: **\(mediaName)**")
                    .font(.callout.bold())
            }
            Text(.init(quirk.symptom))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("**Suggested workaround:** " + quirk.workaround)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let ref = quirk.referenceURL, let url = URL(string: ref) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.caption)
                        Text("Details")
                            .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14, tint: .orange.opacity(0.18))
    }
}
