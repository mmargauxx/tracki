import SwiftUI
import Combine

@MainActor
final class TimerViewModel: ObservableObject {
    enum Screen { case timer, settings }
    enum ConnectionState: Equatable { case disconnected, connecting, connected, failed(String) }

    @Published var screen: Screen = .settings
    @Published var apiTokenInput: String = ""
    @Published var organizationIdInput: String = UserDefaults.standard.string(forKey: "organizationId") ?? ""
    @Published var connectionState: ConnectionState = .disconnected
    @Published var timerDescription: String = ""
    @Published var selectedClientId: Int? = nil {
        didSet {
            if let projectId = selectedProjectId,
               !filteredProjects.contains(where: { $0.id == projectId }) {
                selectedProjectId = nil
            }
        }
    }
    @Published var selectedProjectId: Int? = nil
    @Published var projects: [TogglProject] = []
    @Published var clients: [TogglClient] = []
    @Published var runningEntry: TimeEntry?
    @Published var elapsedText: String = "00:00:00"
    @Published var errorMessage: String?
    @Published var isBusy: Bool = false
    /// Completed entries that failed to sync — kept so the user can re-add them in Toggl's web view.
    @Published var pendingEntries: [PendingEntry] = []

    var onStatusChange: ((String?) -> Void)?

    var isRunning: Bool { runningEntry != nil || localRunStart != nil }

    /// True when we're not talking to Toggl — the timer still runs locally and syncs later.
    var isOffline: Bool { connectionState != .connected }

    /// True while a locally-tracked (offline) run is in progress.
    var isRunningLocally: Bool { localRunStart != nil }

    /// A `toggl_sk_` key targets Toggl 2.0, which needs an organization id.
    var isV2Token: Bool { TogglBackendFactory.isV2Token(apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var filteredProjects: [TogglProject] {
        let filtered: [TogglProject]
        if let clientId = selectedClientId {
            filtered = projects.filter { $0.clientId == clientId }
        } else {
            filtered = projects
        }
        return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var backend: (any TogglBackend)?
    private var tickTimer: Timer?
    private let pendingStore = PendingEntryStore()

    private static let localRunKey = "localRunStart"
    /// A timer started while Toggl was unreachable. Persisted so an in-progress offline run
    /// survives an app restart; it's synced to Toggl on stop (or via the pending queue).
    private var localRunStart: Date? {
        didSet {
            if let localRunStart {
                UserDefaults.standard.set(localRunStart, forKey: Self.localRunKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.localRunKey)
            }
        }
    }

    func onAppearLoad() {
        pendingEntries = pendingStore.entries
        // Restore an offline run that was in progress when the app last quit.
        if let saved = UserDefaults.standard.object(forKey: Self.localRunKey) as? Date {
            localRunStart = saved
            startTicking()
        }
        if let token = KeychainHelper.loadToken(), !token.isEmpty {
            apiTokenInput = token
            connect(token: token)
        } else {
            connectionState = .disconnected
            screen = isRunning ? .timer : .settings
        }
    }

    func saveTokenAndConnect() {
        let token = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        apiTokenInput = token
        KeychainHelper.saveToken(token)
        persistOrganizationId()
        connect(token: token)
    }

    func startStop() {
        errorMessage = nil
        guard !isBusy else { return }
        isBusy = true
        Task {
            if isRunning {
                await stopCurrent()
            } else {
                await startNew()
            }
            isBusy = false
        }
    }

    /// Begin a timer. Uses a real Toggl entry when connected; otherwise tracks locally
    /// (offline) so the user can keep working — it's synced later.
    private func startNew() async {
        let description = timerDescription
        let projectId = selectedProjectId
        if connectionState == .connected, let backend {
            do {
                let entry = try await backend.start(description: description, projectId: projectId)
                runningEntry = entry
                startTicking()
                return
            } catch {
                // The API failed at start — fall through to a local run so tracking still begins.
                errorMessage = "Toggl is unreachable — tracking locally, will sync when it's back."
            }
        }
        localRunStart = Date()
        startTicking()
    }

    /// Stop the running timer. A server-backed entry is updated + stopped; an offline run
    /// is pushed immediately if we're back online, otherwise queued. The timer always clears.
    private func stopCurrent() async {
        let end = Date()
        let description = timerDescription
        let projectId = selectedProjectId

        if let entry = runningEntry {
            do {
                guard let backend else { throw TogglAPIError.configuration("Not connected") }
                // Push any edits made while running, then stop (409/404 handled by the backend).
                try await backend.update(entryId: entry.id, description: description, projectId: projectId)
                try await backend.stop(entry: entry)
            } catch {
                queuePending(description: description, projectId: projectId, start: entry.start, end: end, error: error)
            }
        } else if let start = localRunStart {
            // A locally-tracked run never reached the server. Push it now if we can, else queue.
            if connectionState == .connected, let backend {
                do {
                    try await backend.createCompleted(description: description, projectId: projectId, start: start, end: end)
                } catch {
                    queuePending(description: description, projectId: projectId, start: start, end: end, error: error)
                }
            } else {
                queuePending(description: description, projectId: projectId, start: start, end: end, error: nil)
            }
        }

        clearRunningState()
    }

    private func queuePending(description: String, projectId: Int?, start: Date, end: Date, error: Error?) {
        let pending = PendingEntry(id: UUID(), description: description, projectId: projectId, start: start, end: end)
        pendingStore.add(pending)
        pendingEntries = pendingStore.entries
        if let error {
            errorMessage = "Couldn't sync to Toggl — saved locally, will retry when it's back. (\(error.localizedDescription))"
        } else {
            errorMessage = "Saved locally — will sync to Toggl automatically when it's back up."
        }
    }

    private func clearRunningState() {
        runningEntry = nil
        localRunStart = nil
        stopTicking()
        elapsedText = "00:00:00"
        onStatusChange?(nil)
        timerDescription = ""
    }

    /// Push any locally-queued entries to Toggl. Called after a successful (re)connect and
    /// when the popover opens. Entries that still fail stay queued for the next attempt.
    func syncPending() async {
        guard connectionState == .connected, let backend, !pendingStore.entries.isEmpty else { return }
        for entry in pendingStore.entries {
            do {
                try await backend.createCompleted(
                    description: entry.description,
                    projectId: entry.projectId,
                    start: entry.start,
                    end: entry.end
                )
                pendingStore.remove(id: entry.id)
            } catch {
                // Leave it queued; try again on the next reconnect / popover open.
            }
        }
        pendingEntries = pendingStore.entries
    }

    /// Dismiss a locally-saved entry once the user has re-added it in the Toggl web view.
    func dismissPending(_ id: UUID) {
        pendingStore.remove(id: id)
        pendingEntries = pendingStore.entries
    }

    /// Project name for display of pending entries and pickers.
    func projectName(for id: Int?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    private func persistOrganizationId() {
        let trimmed = organizationIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "organizationId")
    }

    private var parsedOrganizationId: Int? {
        Int(organizationIdInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func popoverOpened() {
        // If we dropped offline, retry the connection; a success flushes the pending queue.
        reconnectIfNeeded()
        Task { await syncPending() }
        guard connectionState == .connected, !isRunning, timerDescription.isEmpty else { return }
        if let tab = BrowserTabReader.frontmostPRTab() {
            timerDescription = tab.title
        }
    }

    /// Re-attempt the connection when we have a token but aren't currently connected.
    private func reconnectIfNeeded() {
        guard connectionState != .connected, connectionState != .connecting else { return }
        let token = apiTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        connect(token: token)
    }

    func descriptionChanged(_ newValue: String) {
        guard let ref = GitHubPRURLParser.parse(newValue) else { return }
        let urlText = newValue
        Task {
            do {
                let title = try await GitHubAPIClient().fetchPRTitle(ref)
                if timerDescription == urlText {
                    timerDescription = title
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func connect(token: String) {
        errorMessage = nil
        connectionState = .connecting
        let backend = TogglBackendFactory.make(apiToken: token, organizationId: parsedOrganizationId)
        self.backend = backend
        Task {
            // Only token validation / workspace resolution can block login.
            do {
                try await backend.connect()
            } catch {
                connectionState = .failed(error.localizedDescription)
                // A connectivity failure (vs. bad credentials) still lets the user run a local
                // timer that syncs later, so keep them on the timer screen instead of Settings.
                if case TogglAPIError.network = error {
                    screen = .timer
                    errorMessage = "Toggl is unreachable — the timer runs locally and syncs when it's back."
                } else {
                    screen = isRunning ? .timer : .settings
                }
                return
            }

            // Logged in. Load supporting data best-effort — a plan gate (HTTP 402), a missing
            // org id, or any single endpoint failing must NOT block using the timer.
            clients = (try? await backend.fetchClients()) ?? []

            do {
                projects = try await backend.fetchProjects()
                if let entry = try await backend.currentEntry() {
                    runningEntry = entry
                    timerDescription = entry.description ?? ""
                    selectedProjectId = entry.projectId
                    startTicking()
                }
            } catch TogglAPIError.configuration(let message) {
                projects = []
                errorMessage = message
            } catch TogglAPIError.http(let status, _) where status == 402 {
                projects = []
                errorMessage = "Your Toggl plan doesn't include API access to projects (HTTP 402). The timer still works — time syncs on stop."
            } catch {
                // Non-fatal — stay connected and surface the reason.
                projects = []
                errorMessage = error.localizedDescription
            }

            connectionState = .connected
            screen = .timer
            // Back online — flush anything tracked while we were offline.
            await syncPending()
        }
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tick()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        let start: Date
        if let entry = runningEntry {
            start = entry.start
        } else if let local = localRunStart {
            start = local
        } else {
            return
        }
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        let text = Self.formatElapsed(seconds)
        elapsedText = text
        onStatusChange?(text)
    }

    private static func formatElapsed(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
