import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: TimerViewModel

    var body: some View {
        Group {
            switch viewModel.screen {
            case .timer:
                TimerView(viewModel: viewModel)
            case .settings:
                SettingsView(viewModel: viewModel)
            }
        }
        // No SwiftUI animation on the screen switch: the popover frame resizes instantly
        // (animates = false), so animating the content inside it only produces a clipped,
        // jumping crossfade.
        .frame(width: 320)
    }
}
