import SwiftUI
import MactoyKit

/// The four modes, as a segmented control in the window toolbar. On macOS 26
/// the toolbar draws it on Liquid Glass.
struct ModePicker: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Picker("Mode", selection: $state.mode) {
            ForEach(AppMode.allCases, id: \.self) { mode in
                // Text only: a toolbar segmented control drops a Label's title and shows bare icons.
                Text(mode.displayName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
