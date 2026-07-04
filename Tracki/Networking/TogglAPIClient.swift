import Foundation

enum TogglAPIError: LocalizedError {
    case unauthorized
    case http(status: Int, body: String)
    case network(Error)
    case decoding(Error)
    case configuration(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Invalid API token"
        case .http(let status, let body):
            return "Toggl API error (HTTP \(status)): \(body)"
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .configuration(let message):
            return message
        }
    }
}

struct TogglAPIClient {
    let apiToken: String

    private static let baseURL = URL(string: "https://api.toggl.com/api/v9")!

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date format: \(string)"
            )
        }
        return decoder
    }()

    init(apiToken: String) {
        self.apiToken = apiToken
    }

    func fetchMe() async throws -> TogglUser {
        try await request(method: "GET", path: "me")
    }

    func fetchWorkspaces() async throws -> [TogglWorkspace] {
        try await request(method: "GET", path: "workspaces")
    }

    func fetchProjects(workspaceId: Int) async throws -> [TogglProject] {
        try await request(method: "GET", path: "workspaces/\(workspaceId)/projects", query: [URLQueryItem(name: "active", value: "true")])
    }

    func fetchClients(workspaceId: Int) async throws -> [TogglClient] {
        try await request(method: "GET", path: "workspaces/\(workspaceId)/clients")
    }

    func fetchCurrentTimeEntry() async throws -> TimeEntry? {
        let data = try await requestData(method: "GET", path: "me/time_entries/current")
        if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        return try decode(TimeEntry.self, from: data)
    }

    func startTimeEntry(workspaceId: Int, description: String, projectId: Int?) async throws -> TimeEntry {
        var body: [String: Any] = [
            "created_with": "Tracki",
            "description": description,
            "workspace_id": workspaceId,
            "start": Self.plainFormatter.string(from: Date()),
            "duration": -1
        ]
        if let projectId {
            body["project_id"] = projectId
        }
        return try await request(method: "POST", path: "workspaces/\(workspaceId)/time_entries", body: body)
    }

    func updateTimeEntry(workspaceId: Int, entryId: Int64, description: String, projectId: Int?) async throws -> TimeEntry {
        let body: [String: Any] = [
            "description": description,
            "project_id": projectId as Any? ?? NSNull()
        ]
        return try await request(method: "PUT", path: "workspaces/\(workspaceId)/time_entries/\(entryId)", body: body)
    }

    func stopTimeEntry(workspaceId: Int, entryId: Int64) async throws -> TimeEntry {
        try await request(method: "PATCH", path: "workspaces/\(workspaceId)/time_entries/\(entryId)/stop")
    }

    /// Create an already-finished entry (positive `duration` + `start`), used to sync
    /// time that was tracked locally while the API was unreachable.
    func createCompletedTimeEntry(workspaceId: Int, description: String, projectId: Int?, start: Date, end: Date) async throws -> TimeEntry {
        let duration = max(0, Int(end.timeIntervalSince(start)))
        var body: [String: Any] = [
            "created_with": "Tracki",
            "description": description,
            "workspace_id": workspaceId,
            "start": Self.plainFormatter.string(from: start),
            "stop": Self.plainFormatter.string(from: end),
            "duration": duration
        ]
        if let projectId {
            body["project_id"] = projectId
        }
        return try await request(method: "POST", path: "workspaces/\(workspaceId)/time_entries", body: body)
    }

    private func request<T: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await requestData(method: method, path: path, query: query, body: body)
        return try decode(T.self, from: data)
    }

    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: [String: Any]? = nil
    ) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let query {
            components.queryItems = query
        }
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = method
        let credentials = Data("\(apiToken):api_token".utf8).base64EncodedString()
        urlRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
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
        case 200..<300:
            return data
        case 401, 403:
            throw TogglAPIError.unauthorized
        default:
            throw TogglAPIError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw TogglAPIError.decoding(error)
        }
    }
}
