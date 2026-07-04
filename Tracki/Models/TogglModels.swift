import Foundation

struct TogglUser: Codable {
    let id: Int
    let fullname: String
    let defaultWorkspaceId: Int

    enum CodingKeys: String, CodingKey {
        case id, fullname
        case defaultWorkspaceId = "default_workspace_id"
    }
}

struct TogglWorkspace: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct TogglProject: Codable, Identifiable, Hashable {
    let id: Int
    let workspaceId: Int
    let clientId: Int?
    let name: String
    let color: String?
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, color, active
        case workspaceId = "workspace_id"
        case clientId = "client_id"
    }
}

struct TogglClient: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
}

struct TimeEntry: Codable, Identifiable {
    let id: Int64
    let workspaceId: Int
    let projectId: Int?
    let description: String?
    let start: Date
    let duration: Int64

    enum CodingKeys: String, CodingKey {
        case id, description, start, duration
        case workspaceId = "workspace_id"
        case projectId = "project_id"
    }
}
