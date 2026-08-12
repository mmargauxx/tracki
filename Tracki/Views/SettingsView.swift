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

            remindersSection

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

    /// Periodic "you're still tracking" flyby. Only fires while a timer is running.
    private var remindersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Remind me", selection: $viewModel.reminderInterval) {
                ForEach(ReminderInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 6) {
                Text(viewModel.reminderInterval == .off
                     ? "No reminders while tracking."
                     : "Flies across the screen while a timer runs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Preview", action: viewModel.previewFlyby)
                    .buttonStyle(.link)
                    .font(.caption)
            }

            flybyImageControls
        }
    }

    /// Swap the artwork that flies across the screen.
    private var flybyImageControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Choose Image…", action: chooseFlybyImage)
                    .controlSize(.small)
                if viewModel.hasCustomFlybyImage {
                    Button("Reset", action: viewModel.resetFlybyImage)
                        .controlSize(.small)
                }
                Spacer()
            }

            Toggle("Remove background", isOn: $viewModel.flybyRemoveBackground)
                .toggleStyle(.checkbox)
                .font(.caption)

            Text(viewModel.flybyMessage
                 ?? "Most images have a solid background, which would fly as a rectangle.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseFlybyImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose the image that flies across your screen"
        panel.prompt = "Use Image"
        // The popover is transient and closes when the panel takes focus; activating first
        // makes sure the panel comes to the front of an accessory (LSUIElement) app.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.importFlybyImage(from: url)
    }
}
