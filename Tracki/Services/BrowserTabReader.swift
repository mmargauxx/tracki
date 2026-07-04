import AppKit
import Foundation

struct BrowserPRTab {
    let title: String
    let ref: GitHubPRRef
}

enum BrowserTabReader {
    private static let safariID = "com.apple.Safari"
    private static let chromeID = "com.google.Chrome"
    private static let arcID = "company.thebrowser.Browser"

    /// Checks running browsers (frontmost first, then Safari, Chrome, Arc) and
    /// returns the first whose active tab URL parses as a GitHub PR.
    /// Must be called on the main thread (NSAppleScript is not thread-safe).
    @MainActor
    static func frontmostPRTab() -> BrowserPRTab? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var order = [safariID, chromeID, arcID].filter(running.contains)

        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           order.contains(front) {
            order.removeAll { $0 == front }
            order.insert(front, at: 0)
        }

        for bundleID in order {
            guard
                let tab = activeTab(bundleID: bundleID),
                let ref = GitHubPRURLParser.parse(tab.url)
            else { continue }
            return BrowserPRTab(title: cleanTitle(tab.title), ref: ref)
        }
        return nil
    }

    // MARK: - AppleScript

    private static func activeTab(bundleID: String) -> (url: String, title: String)? {
        guard
            let source = scriptSource(for: bundleID),
            let script = NSAppleScript(source: source)
        else { return nil }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard
            errorInfo == nil,
            let combined = result.stringValue,
            let newline = combined.firstIndex(of: "\n")
        else { return nil }

        let url = String(combined[..<newline])
        let title = String(combined[combined.index(after: newline)...])
        guard !url.isEmpty else { return nil }
        return (url, title)
    }

    private static func scriptSource(for bundleID: String) -> String? {
        switch bundleID {
        case safariID:
            return #"tell application "Safari" to if (count of windows) > 0 then return (URL of current tab of front window) & "\n" & (name of current tab of front window)"#
        case chromeID:
            return #"tell application "Google Chrome" to if (count of windows) > 0 then return (URL of active tab of front window) & "\n" & (title of active tab of front window)"#
        case arcID:
            return #"tell application "Arc" to if (count of windows) > 0 then return (URL of active tab of front window) & "\n" & (title of active tab of front window)"#
        default:
            return nil
        }
    }

    // MARK: - Title cleaning

    /// "(2) Fix login race by alice · Pull Request #123 · acme/webapp" -> "Fix login race"
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let leading = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            title.removeSubrange(leading)
        }

        if let marker = title.range(of: " · Pull Request #") {
            title = String(title[..<marker.lowerBound])
        } else if let separator = title.range(of: " · ") {
            title = String(title[..<separator.lowerBound])
        }

        let withoutSuffixes = title.trimmingCharacters(in: .whitespaces)

        if let byRange = title.range(of: " by ", options: .backwards) {
            title = String(title[..<byRange.lowerBound])
        }
        title = title.trimmingCharacters(in: .whitespaces)

        return title.isEmpty ? withoutSuffixes : title
    }
}
