import Foundation
import UserNotifications

/// Tells you when a newer release exists. Nothing is downloaded or installed — Homebrew owns
/// that — and no information about you is sent. It is one unauthenticated GET for a tag name.
// ponytail: cache checks briefly so repeatedly opening the panel does not hammer GitHub, but do
//           let the cache expire. Otherwise a release published while the app is running stays
//           invisible in the panel until the six-hour background check or an app restart.
enum Update {
    static let repo = "RaazKetan/claude-session-manager"
    static let formula = "raazketan/tap/claude-session-manager"
    static let cask = "claude-sessions"

    /// The single command that updates *this* copy.
    ///
    /// Three ways in, three commands out: the cask drops the prebuilt app in /Applications, the
    /// formula builds from source under Homebrew's prefix, and install.sh copies to /Applications
    /// with Homebrew knowing nothing about it.
    ///
    // ponytail: the app can see where it is standing, so it never has to guess. This was one
    //           hard-coded cask upgrade for everybody, which answered "Cask 'claude-sessions' is
    //           not installed" for anyone who took the build-from-source route.
    static var upgradeCommand: String {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return "brew upgrade \(formula)" }
        let caskroom = ["/opt/homebrew", "/usr/local"].map { "\($0)/Caskroom/\(cask)" }
        guard caskroom.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | zsh"
        }
        return "brew upgrade --cask \(cask)"
    }

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static var cached: (checkedAt: Date, result: String?)?
    private static let cacheLifetime: TimeInterval = 60

    /// The newer version's tag, or nil when up to date, offline, or running an unreleased build.
    static func newerVersion() async -> String? {
        if let cached, Date().timeIntervalSince(cached.checkedAt) < cacheLifetime {
            return cached.result
        }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }   // don't cache failures; the next launch can retry

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let result = isNewer(latest, than: current) ? latest : nil
        cached = (Date(), result)
        return result
    }

    /// Checks now, then every six hours, and says so once per release — in Notification Center,
    /// and as a line new terminals print, so you hear about it without opening the panel.
    static func watch() {
        Task {
            while true {
                let newer = await newerVersion()
                writeShellNotice(newer)
                if let newer, UserDefaults.standard.string(forKey: "notifiedVersion") != newer {
                    UserDefaults.standard.set(newer, forKey: "notifiedVersion")
                    notify(newer)
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
                cached = nil   // so the next round actually asks GitHub again
            }
        }
    }

    // ponytail: UNUserNotificationCenter asks the system for a bundle id and traps without one,
    //           which is exactly how `swift run` runs it. No bundle, no banner.
    private static func notify(_ version: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Claude Sessions \(version) is out"
            content.body = upgradeCommand
            center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
        }
    }

    /// The line new shells print, or nothing once you are up to date.
    ///
    // ponytail: the app writes the message, `.zshrc` only cats it. A shell that has to check for
    //           itself is a shell that waits on the network before it gives you a prompt.
    static let noticeFile = Names.url.deletingLastPathComponent().appendingPathComponent("update-notice")

    private static func writeShellNotice(_ version: String?) {
        guard let version else { try? FileManager.default.removeItem(at: noticeFile); return }
        let line = "[claude-sessions] \(version) is out (you have \(current)) — \(upgradeCommand)\n"
        try? FileManager.default.createDirectory(at: noticeFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? line.write(to: noticeFile, atomically: true, encoding: .utf8)
    }

    /// Adds the two lines that print it, once, keeping a copy of the file as it was.
    static func installShellNotice() {
        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let marker = "# claude-sessions update notice"
        let existing = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        guard !existing.contains(marker) else { return }

        if !existing.isEmpty {   // never touch someone's shell setup without leaving a way back
            try? existing.write(to: zshrc.appendingPathExtension("claude-sessions-backup"),
                                atomically: true, encoding: .utf8)
        }
        let notice = """

            \(marker) — delete these two lines to stop it
            [ -s "\(noticeFile.path)" ] && cat "\(noticeFile.path)"

            """
        try? (existing + notice).write(to: zshrc, atomically: true, encoding: .utf8)
    }

    /// Numeric compare, so 1.10.0 beats 1.9.0 rather than losing a string comparison.
    static func isNewer(_ candidate: String, than existing: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = existing.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
