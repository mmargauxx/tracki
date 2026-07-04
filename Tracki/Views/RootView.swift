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
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.15), value: viewModel.screen)
    }
}
