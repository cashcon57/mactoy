import SwiftUI
import MactoyKit

/// Update Ventoy in-place on a drive that already has it. Adapts to the
/// probe result on `state.detectedVentoy`:
///
/// - **No disk selected** → tells the user to pick one in the sidebar.
/// - **Probing** (selection just changed, probe in flight) → spinner.
/// - **Up-to-date** (`detectedVersion == latestVentoyVersion`) → "no
///   update needed" with a hint about the Install Ventoy tab if they
///   want to wipe-and-reinstall anyway.
/// - **Update available** (`detectedVersion < latestVentoyVersion` or
///   the user explicitly picks a different version) → primary CTA goes
///   to the ActionBar's "Update Ventoy" button.
/// - **Looks like broken Ventoy** (`looksLikeBrokenVentoy == true`) →
///   "this drive's Ventoy install is corrupted; repair via fresh
///   install (which erases your ISOs)" — bounces the user to the
///   Install Ventoy tab with a warning.
/// - **Not Ventoy** → "this disk doesn't have Ventoy; use the Install
///   Ventoy tab for a fresh install".
struct UpdateVentoyPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Update Ventoy")
                    .font(.title.bold())
                if let latest = state.latestVentoyVersion {
                    Text("latest: v\(latest)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What this does")
                    .font(.headline)
                Text("Updates the Ventoy bootloader on a drive that already has Ventoy installed, **without erasing your ISOs or `/ventoy/` configuration**. Only the bootloader regions of the drive are rewritten — partition 1 is never touched.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .mactoyGlass(cornerRadius: 16)

            // Adaptive content based on probe state.
            stateView

            Spacer()
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if state.selectedDisk == nil {
            DiskNotSelectedHint()
        } else if let errorMessage = state.probeError {
            ProbeFailedHint(message: errorMessage) {
                state.triggerVentoyProbe()
            }
        } else if let probe = state.detectedVentoy {
            if probe.isVentoyDisk {
                ventoyDetectedView(probe)
            } else if probe.looksLikeBrokenVentoy {
                BrokenVentoyHint(issues: probe.layoutIssues)
            } else {
                NoVentoyHint(issues: probe.layoutIssues)
            }
        } else {
            // Probe in flight (300ms debounce + XPC roundtrip).
            ProbingHint()
        }
    }

    @ViewBuilder
    private func ventoyDetectedView(_ probe: VentoyProbeResult) -> some View {
        let detectedVer = probe.detectedVersion ?? "?"
        let latestVer = state.latestVentoyVersion ?? ""
        let isUpToDate = !latestVer.isEmpty && detectedVer == latestVer

        VStack(alignment: .leading, spacing: 8) {
            Text(isUpToDate ? "Already up to date" : "Update available")
                .font(.headline)
            HStack(spacing: 8) {
                Image(systemName: isUpToDate ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                    .foregroundStyle(isUpToDate ? Color.green : Color.accentColor)
                Text("Currently installed: **v\(detectedVer)**")
                    .font(.callout)
            }
            if !latestVer.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.secondary)
                    Text("Latest available: **v\(latestVer)**")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if probe.secureBootEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.secondary)
                    Text("Secure boot is enabled on this drive — your setting will be preserved across the update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isUpToDate {
                Text("If you want to refresh the bootloader anyway, switch to the **Install Ventoy** tab to reinstall (this erases your ISOs).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(
            cornerRadius: 14,
            tint: isUpToDate ? .green.opacity(0.15) : .accentColor.opacity(0.18)
        )

        // Version picker — same UI as Install Ventoy. Defaults to
        // "Latest" so user can just click Update; advanced users can
        // pin a specific version.
        VersionPicker()
    }
}

// MARK: - Hints

private struct DiskNotSelectedHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Select a disk in the sidebar to check for Ventoy.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProbeFailedHint: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't probe this disk")
                    .font(.callout.bold())
            }
            Text(.init(message))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Try again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14, tint: .orange.opacity(0.15))
    }
}

private struct ProbingHint: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking selected disk for Ventoy...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14)
    }
}

private struct NoVentoyHint: View {
    let issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("This disk does not have Ventoy installed.")
                    .font(.callout.bold())
            }
            Text("To put Ventoy on this drive, switch to the **Install Ventoy** tab. That'll do a fresh install — note that it erases everything on the disk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !issues.isEmpty {
                DisclosureGroup("Probe details") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { issue in
                            Text("• \(issue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14)
    }
}

private struct BrokenVentoyHint: View {
    let issues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Ventoy install looks damaged")
                    .font(.callout.bold())
            }
            Text("This drive has the partition geometry of a Ventoy install but doesn't pass the full layout check — the bootloader was likely interrupted mid-install or the drive was tampered with by another tool. An in-place update can't safely run on a damaged install.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("**To repair**: switch to the **Install Ventoy** tab and run a fresh install. This will erase the entire drive (including any ISOs that survived) and put a clean Ventoy on it.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Probe details") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        Text("• \(issue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mactoyGlass(cornerRadius: 14, tint: .orange.opacity(0.18))
    }
}

// MARK: - Version picker (mirror of InstallVentoyPanel's)

private struct VersionPicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Version to install")
                .font(.headline)
            HStack(spacing: 12) {
                Menu {
                    Button("Latest") {
                        state.useCustomVentoyVersion = false
                        state.ventoyVersionInput = ""
                    }
                    if !state.availableVentoyVersions.isEmpty {
                        Divider()
                        ForEach(state.availableVentoyVersions, id: \.self) { v in
                            Button("v\(v)") {
                                state.useCustomVentoyVersion = false
                                state.ventoyVersionInput = v
                            }
                        }
                    }
                    Divider()
                    Button("Custom…") {
                        state.useCustomVentoyVersion = true
                        if state.customVentoyVersion.isEmpty {
                            state.customVentoyVersion = state.ventoyVersionInput
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(menuLabel)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(minWidth: 200, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .mactoyGlass(cornerRadius: 10, interactive: true)

                if state.useCustomVentoyVersion {
                    TextField("e.g. 1.1.11", text: $state.customVentoyVersion)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    Text("enter a Ventoy release tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(state.availableVentoyVersions.isEmpty
                         ? "resolves latest at update time"
                         : "pick an older release or choose Custom…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var menuLabel: String {
        if state.useCustomVentoyVersion {
            return "Custom"
        }
        let sel = state.ventoyVersionInput.trimmingCharacters(in: .whitespaces)
        if sel.isEmpty {
            if let latest = state.latestVentoyVersion {
                return "Latest (v\(latest))"
            }
            return "Latest"
        }
        return "v\(sel)"
    }
}
