import Foundation

/// Abstraction over the two Toggl APIs so the view model is backend-agnostic:
/// classic Toggl Track v9 (HTTP Basic, 32-hex token) and Toggl 2.0 / Focus
/// (Bearer `toggl_sk_` key). Each backend resolves and caches its own
/// workspace/organization context during `connect()`.
protocol TogglBackend: AnyObject {
    /// Validates the token and resolves the workspace (and organization, for v2).
    func connect() async throws
    func fetchProjects() async throws -> [TogglProject]
    func fetchClients() async throws -> [TogglClient]
    func currentEntry() async throws -> TimeEntry?
    func start(description: String, projectId: Int?) async throws -> TimeEntry
    /// Edit a running entry's description/project. No-op-safe if unsupported.
    func update(entryId: Int64, description: String, projectId: Int?) async throws
    /// Stops the entry. Returns normally if it was already stopped/gone (HTTP 409/404).
    /// Takes the full entry so a fallback can compute its duration from `start`.
    func stop(entry: TimeEntry) async throws
    /// Push an already-completed entry — used to sync time tracked locally while offline.
    func createCompleted(description: String, projectId: Int?, start: Date, end: Date) async throws
}

enum TogglBackendFactory {
    /// A `toggl_sk_` prefix selects the Toggl 2.0 backend; anything else is classic v9.
    static func isV2Token(_ token: String) -> Bool {
        token.hasPrefix("toggl_sk_")
    }

    static func make(apiToken: String, organizationId: Int?) -> any TogglBackend {
        if isV2Token(apiToken) {
            return TogglV2Client(apiToken: apiToken, organizationId: organizationId)
        }
        return ClassicTogglBackend(apiToken: apiToken)
    }
}

/// Wraps the low-level classic v9 client, caching the default workspace and
/// treating a 409 on stop (already stopped) as success.
final class ClassicTogglBackend: TogglBackend {
    private let api: TogglAPIClient
    private var workspaceId: Int?

    init(apiToken: String) {
        self.api = TogglAPIClient(apiToken: apiToken)
    }

    func connect() async throws {
        workspaceId = try await api.fetchMe().defaultWorkspaceId
    }

    private func resolvedWorkspaceId() throws -> Int {
        guard let workspaceId else { throw TogglAPIError.configuration("Not connected") }
        return workspaceId
    }

    func fetchProjects() async throws -> [TogglProject] {
        try await api.fetchProjects(workspaceId: try resolvedWorkspaceId())
    }

    func fetchClients() async throws -> [TogglClient] {
        try await api.fetchClients(workspaceId: try resolvedWorkspaceId())
    }

    func currentEntry() async throws -> TimeEntry? {
        try await api.fetchCurrentTimeEntry()
    }

    func start(description: String, projectId: Int?) async throws -> TimeEntry {
        try await api.startTimeEntry(workspaceId: try resolvedWorkspaceId(), description: description, projectId: projectId)
    }

    func update(entryId: Int64, description: String, projectId: Int?) async throws {
        do {
            _ = try await api.updateTimeEntry(workspaceId: try resolvedWorkspaceId(), entryId: entryId, description: description, projectId: projectId)
        } catch TogglAPIError.http(let status, _) where status == 404 {
            return // entry gone — nothing to update, let the stop that follows clear it
        }
    }

    func stop(entry: TimeEntry) async throws {
        do {
            _ = try await api.stopTimeEntry(workspaceId: try resolvedWorkspaceId(), entryId: entry.id)
        } catch TogglAPIError.http(let status, _) where status == 409 || status == 404 {
            return // 409 already stopped, 404 entry not found — nothing left to stop
        }
    }

    func createCompleted(description: String, projectId: Int?, start: Date, end: Date) async throws {
        _ = try await api.createCompletedTimeEntry(
            workspaceId: try resolvedWorkspaceId(),
            description: description,
            projectId: projectId,
            start: start,
            end: end
        )
    }
}
