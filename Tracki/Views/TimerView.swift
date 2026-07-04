import SwiftUI

struct TimerView: View {
    @ObservedObject var viewModel: TimerViewModel

    var body: some View {
        VStack(spacing: 12) {
            header

            Text(viewModel.elapsedText)
                .font(.largeTitle.monospacedDigit())
                .frame(maxWidth: .infinity)

            TextField("What are you working on?", text: $viewModel.timerDescription)
                .textFieldStyle(.roundedBorder)
                .onChange(of: viewModel.timerDescription) { newValue in
                    viewModel.descriptionChanged(newValue)
                }

            Picker("Client", selection: $viewModel.selectedClientId) {
                Text("All Clients").tag(Int?.none)
                ForEach(viewModel.clients) { client in
                    Text(client.name).tag(Int?.some(client.id))
                }
            }
            .pickerStyle(.menu)

            Picker("Project", selection: $viewModel.selectedProjectId) {
                Text("No Project").tag(Int?.none)
                ForEach(viewModel.filteredProjects) { project in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(hex: project.color) ?? .secondary)
                            .frame(width: 8, height: 8)
                        Text(project.name)
                    }
                    .tag(Int?.some(project.id))
                }
            }
            .pickerStyle(.menu)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: viewModel.startStop) {
                Label(startButtonTitle, systemImage: viewModel.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(viewModel.isRunning ? .red : .green)
            .disabled(viewModel.isBusy || viewModel.connectionState == .connecting)

            if viewModel.isOffline && viewModel.connectionState != .connecting {
                Label("Offline — tracking locally, syncs when Toggl is back", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !viewModel.pendingEntries.isEmpty {
                unsyncedSection
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var startButtonTitle: String {
        if viewModel.isRunning { return "Stop" }
        return viewModel.isOffline ? "Start Offline" : "Start"
    }

    private var unsyncedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Label("Unsynced — re-add in Toggl web", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption.weight(.semibold))
                .foregroundColor(.orange)
            ForEach(viewModel.pendingEntries) { entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.description.isEmpty ? "(no description)" : entry.description)
                            .font(.caption)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(entry.durationText).monospacedDigit()
                            if let name = viewModel.projectName(for: entry.projectId) {
                                Text("· \(name)").lineLimit(1)
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        viewModel.dismissPending(entry.id)
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Mark as re-added and remove")
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Tracki")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                viewModel.screen = .settings
            } label: {
                Image(systemName: "gearshape")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
