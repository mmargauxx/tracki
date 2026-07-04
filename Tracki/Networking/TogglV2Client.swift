import Foundation

/// Toggl 2.0 / Focus backend for `toggl_sk_` keys.
/// Base `https://focus.toggl.com/api`, `Authorization: Bearer <token>`.
/// See docs/toggl-v2-api.md for the reverse-engineered endpoint map.
///
/// Projects and timer tracking are organization-scoped and the organization id
/// cannot be auto-discovered with an API key, so it is supplied by the user.
/// Clients load without it.
final class TogglV2Client: TogglBackend {
    private let apiToken: String
    private let organizationId: Int?
    private var workspaceId: Int?

    private static let baseURL = URL(string: "https://focus.toggl.com/api")!

    private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractional.date(from: string) ?? plain.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date: \(string)")
        }
        return decoder
    }()

    init(apiToken: String, organizationId: Int?) {
        self.apiToken = apiToken
        self.organizationId = organizationId
    }

    // MARK: - Connect

    func connect() async throws {
        let settings: UserSettings = try await request(method: "GET", path: "users/me/settings")
        workspaceId = settings.currentWorkspaceId
    }

    private func resolvedWorkspaceId() throws -> Int {
        guard let workspaceId else { throw TogglAPIError.configuration("Not connected") }
        return workspaceId
    }

    private func resolvedOrganizationId() throws -> Int {
        guard let organizationId else {
            throw TogglAPIError.configuration("Enter your Toggl Organization ID in Settings to load projects and use the timer. Find it in the URL of the Toggl web app.")
        }
        return organizationId
    }

    // MARK: - Data

    func fetchProjects() async throws -> [TogglProject] {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        do {
            let page: Page<V2Project> = try await request(
                method: "GET",
                path: "organizations/\(org)/workspaces/\(ws)/projects",
                query: [URLQueryItem(name: "per_page", value: "200"), URLQueryItem(name: "archived", value: "false")]
            )
            return page.data.map { $0.asTogglProject(workspaceId: ws) }
        } catch let error {
            throw Self.mapOrganizationError(error)
        }
    }

    /// A 400/403 on an org-scoped endpoint almost always means the Organization ID is
    /// wrong or malformed (Toggl returns `invalid_organization_id` on 400, `403` on a
    /// valid-but-not-yours integer). Surface it as an actionable configuration hint so
    /// `connect()` keeps the partial connection (clients already loaded) instead of failing.
    private static func mapOrganizationError(_ error: Error) -> Error {
        guard case TogglAPIError.http(let status, let body) = error, status == 400 || status == 403 else {
            return error
        }
        let reason = body.isEmpty ? "" : " (Toggl said: \(body))"
        return TogglAPIError.configuration(
            "Toggl rejected your Organization ID (HTTP \(status)) — it looks wrong or malformed. "
            + "Copy the number from the URL of your logged-in Toggl web app and re-enter it in Settings.\(reason)"
        )
    }

    func fetchClients() async throws -> [TogglClient] {
        let ws = try resolvedWorkspaceId()
        let page: Page<TogglClient> = try await request(
            method: "GET",
            path: "workspaces/\(ws)/clients",
            query: [URLQueryItem(name: "per_page", value: "200")]
        )
        return page.data
    }

    func currentEntry() async throws -> TimeEntry? {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        do {
            do {
                // 204 No Content when nothing is tracking.
                guard let entry: V2TimeEntry = try await requestOptional(
                    method: "GET",
                    path: "organizations/\(org)/workspaces/\(ws)/tracking/current"
                ) else { return nil }
                return entry.asTimeEntry(workspaceId: ws)
            } catch TogglAPIError.http(let status, _) where status == 402 {
                return try await currentViaTimeEntries(org: org, ws: ws)
            }
        } catch {
            throw Self.mapOrganizationError(error)
        }
    }

    /// Create an already-completed entry (used to sync time tracked while offline).
    /// Uses `/time-entries` with a positive `duration`, which persists a finished entry.
    func createCompleted(description: String, projectId: Int?, start: Date, end: Date) async throws {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        let duration = max(0, Int(end.timeIntervalSince(start)))
        var body: [String: Any] = [
            "description": description,
            "type": "activity",
            "start": Self.rfc3339.string(from: start),
            "stop": Self.rfc3339.string(from: end),
            "duration": duration
        ]
        if let projectId { body["project_id"] = projectId }
        do {
            _ = try await requestOptional(
                method: "POST",
                path: "organizations/\(org)/workspaces/\(ws)/time-entries",
                body: body
            ) as V2TimeEntry?
        } catch {
            throw Self.mapOrganizationError(error)
        }
    }

    func start(description: String, projectId: Int?) async throws -> TimeEntry {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        var body: [String: Any] = [
            "description": description,
            "type": "activity",
            "start": Self.rfc3339.string(from: Date())
        ]
        if let projectId { body["project_id"] = projectId }
        do {
            let entry: V2TimeEntry = try await request(
                method: "POST",
                path: "organizations/\(org)/workspaces/\(ws)/tracking/start",
                body: body
            )
            return entry.asTimeEntry(workspaceId: ws)
        } catch TogglAPIError.http(let status, _) where status == 402 {
            // /tracking is gated on this tier — create a running entry via time-entries.
            let entry: V2TimeEntry = try await request(
                method: "POST",
                path: "organizations/\(org)/workspaces/\(ws)/time-entries",
                body: body
            )
            return entry.asTimeEntry(workspaceId: ws)
        }
    }

    /// Fallback for `currentEntry` when `/tracking` is gated: list recent entries and
    /// return the running one (negative/absent duration), most recent first.
    private func currentViaTimeEntries(org: Int, ws: Int) async throws -> TimeEntry? {
        let now = Date()
        let from = Self.rfc3339.string(from: now.addingTimeInterval(-7 * 24 * 3600))
        let to = Self.rfc3339.string(from: now.addingTimeInterval(24 * 3600))
        let page: Page<V2TimeEntry> = try await request(
            method: "GET",
            path: "organizations/\(org)/workspaces/\(ws)/time-entries",
            query: [
                URLQueryItem(name: "date_from", value: from),
                URLQueryItem(name: "date_to", value: to),
                URLQueryItem(name: "per_page", value: "50")
            ]
        )
        let running = page.data
            .filter { ($0.duration ?? -1) < 0 }
            .sorted { $0.start > $1.start }
            .first
        return running?.asTimeEntry(workspaceId: ws)
    }

    func update(entryId: Int64, description: String, projectId: Int?) async throws {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        let body: [String: Any] = [
            "description": description,
            "project_id": projectId as Any? ?? NSNull()
        ]
        do {
            _ = try await requestOptional(
                method: "PATCH",
                path: "organizations/\(org)/workspaces/\(ws)/time-entries/\(entryId)",
                body: body
            ) as V2TimeEntry?
        } catch TogglAPIError.http(let status, _) where status == 404 {
            return // entry gone — nothing to update, let the stop that follows clear it
        }
    }

    func stop(entry: TimeEntry) async throws {
        let ws = try resolvedWorkspaceId()
        let org = try resolvedOrganizationId()
        do {
            _ = try await requestOptional(
                method: "POST",
                path: "organizations/\(org)/workspaces/\(ws)/tracking/stop",
                body: ["end": Self.rfc3339.string(from: Date())]
            ) as V2TimeEntry?
        } catch TogglAPIError.http(let status, _) where status == 409 || status == 404 {
            return // 409 already stopped, 404 entry not found — nothing left to stop
        } catch TogglAPIError.http(let status, _) where status == 402 {
            // /tracking is gated on this tier — finalize via time-entries by setting a
            // positive duration (elapsed seconds), which stops the running entry.
            let elapsed = max(0, Int(Date().timeIntervalSince(entry.start)))
            do {
                _ = try await requestOptional(
                    method: "PATCH",
                    path: "organizations/\(org)/workspaces/\(ws)/time-entries/\(entry.id)",
                    body: ["duration": elapsed]
                ) as V2TimeEntry?
            } catch TogglAPIError.http(let s, _) where s == 409 || s == 404 {
                return // already stopped/gone
            }
        }
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) async throws -> T {
        guard let value: T = try await requestOptional(method: method, path: path, query: query, body: body) else {
            throw TogglAPIError.decoding(DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: "Empty body")))
        }
        return value
    }

    /// Returns nil on 204 No Content (used by endpoints that may legitimately return empty).
    private func requestOptional<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) async throws -> T? {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let query { components.queryItems = query }
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw TogglAPIError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TogglAPIError.http(status: -1, body: "")
        }
        switch http.statusCode {
        case 204:
            return nil
        case 200..<300:
            if data.isEmpty { return nil }
            do {
                return try Self.decoder.decode(T.self, from: data)
            } catch {
                throw TogglAPIError.decoding(error)
            }
        case 401, 403:
            throw TogglAPIError.unauthorized
        default:
            throw TogglAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Wire models (Toggl 2.0 shapes → shared models)

private struct UserSettings: Decodable {
    let currentWorkspaceId: Int
    enum CodingKeys: String, CodingKey { case currentWorkspaceId = "current_workspace_id" }
}

private struct Page<Element: Decodable>: Decodable {
    let data: [Element]
}

private struct V2Project: Decodable {
    let id: Int
    let name: String
    let color: String?
    let clientId: Int?
    let active: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, color, active
        case clientId = "client_id"
    }

    func asTogglProject(workspaceId: Int) -> TogglProject {
        TogglProject(id: id, workspaceId: workspaceId, clientId: clientId, name: name, color: color, active: active ?? true)
    }
}

private struct V2TimeEntry: Decodable {
    let id: Int64
    let projectId: Int?
    let description: String?
    let start: Date
    let duration: Int64?

    enum CodingKeys: String, CodingKey {
        case id, description, start, duration
        case projectId = "project_id"
    }

    func asTimeEntry(workspaceId: Int) -> TimeEntry {
        TimeEntry(id: id, workspaceId: workspaceId, projectId: projectId, description: description, start: start, duration: duration ?? -1)
    }
}
