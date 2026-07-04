import Foundation

struct GitHubPRRef: Equatable {
    let owner: String
    let repo: String
    let number: Int
}

enum GitHubPRURLParser {
    /// Returns a ref if the ENTIRE trimmed string is a GitHub PR URL:
    /// https://github.com/{owner}/{repo}/pull/{number}  (optional trailing slash,
    /// optional /files|/commits|/checks suffix, optional #fragment or ?query).
    static func parse(_ text: String) -> GitHubPRRef? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host?.lowercased(),
            host == "github.com" || host == "www.github.com"
        else { return nil }

        var parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 5, ["files", "commits", "checks"].contains(parts[4]) {
            parts.removeLast()
        }
        guard
            parts.count == 4,
            parts[2] == "pull",
            !parts[0].isEmpty, !parts[1].isEmpty,
            let number = Int(parts[3]), number > 0
        else { return nil }

        return GitHubPRRef(owner: parts[0], repo: parts[1], number: number)
    }
}

enum GitHubAPIError: LocalizedError {
    case http(status: Int)
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .http(let status):
            switch status {
            case 404: return "Pull request not found (HTTP 404)."
            case 403: return "GitHub API access forbidden — possibly rate limited (HTTP 403)."
            case 429: return "GitHub API rate limit exceeded (HTTP 429)."
            default:  return "GitHub API request failed (HTTP \(status))."
            }
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding(let error):
            return "Could not decode GitHub API response: \(error.localizedDescription)"
        }
    }
}

struct GitHubAPIClient {
    /// GET https://api.github.com/repos/{owner}/{repo}/pulls/{number} (unauthenticated).
    /// Returns the pull request's "title" field.
    func fetchPRTitle(_ ref: GitHubPRRef) async throws -> String {
        guard
            let owner = ref.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let repo = ref.repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/pulls/\(ref.number)")
        else {
            throw GitHubAPIError.http(status: 400)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubAPIError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GitHubAPIError.http(status: http.statusCode)
        }

        do {
            return try JSONDecoder().decode(PRResponse.self, from: data).title
        } catch {
            throw GitHubAPIError.decoding(error)
        }
    }

    private struct PRResponse: Decodable {
        let title: String
    }
}
