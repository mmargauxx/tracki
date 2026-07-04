import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: TimerViewModel

    private var trimmedToken: String {
        viewModel.apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if viewModel.connectionState == .connected {
                    Button {
                        viewModel.screen = .timer
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                }
                Text("Settings")
                    .font(.headline)
                Spacer()
            }

            SecureField("Toggl API Token", text: $viewModel.apiTokenInput)
                .textFieldStyle(.roundedBorder)

            Text("Find your token at track.toggl.com/profile")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.isV2Token {
                TextField("Organization ID", text: $viewModel.organizationIdInput)
                    .textFieldStyle(.roundedBorder)
                Text("Toggl 2.0 key detected. Enter your Organization ID — it's the number in your Toggl web app URL.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button(action: viewModel.saveTokenAndConnect) {
                HStack(spacing: 6) {
                    if viewModel.connectionState == .connecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Save & Connect")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedToken.isEmpty || viewModel.connectionState == .connecting)

            switch viewModel.connectionState {
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            case .disconnected, .connecting:
                EmptyView()
            }

            Divider()

            Button("Quit Tracki") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
        }
        .padding()
        .frame(width: 320)
    }
}
