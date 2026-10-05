import Foundation
import AppKit
import UserNotifications

/// Tells you when a newer release exists. Nothing is downloaded or installed — Homebrew owns
/// that — and no information about you is sent. It is one unauthenticated GET for a tag name.
// ponytail: cache checks briefly so repeatedly opening the panel does not hammer GitHub, but do
//           let the cache expire. Otherwise a release published while the app is running stays
//           invisible in the panel until the six-hour background check or an app restart.
enum Update {
    static let repo = "RaazKetan/creo"
    static let formula = "raazketan/tap/creo"
    static let cask = "creo"

    /// The single command that updates *this* copy.
    ///
    /// Three ways in, three commands out: the cask drops the prebuilt app in /Applications, the
    /// formula builds from source under Homebrew's prefix, and install.sh copies to /Applications
    /// with Homebrew knowing nothing about it.
    ///
    // ponytail: the app can see where it is standing, so it never has to guess. This was one
    //           hard-coded cask upgrade for everybody, which answered "Cask 'creo' is
    //           not installed" for anyone who took the build-from-source route.
    static var upgradeCommand: String {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return "brew upgrade \(formula)" }
        let caskroom = ["/opt/homebrew", "/usr/local"].map { "\($0)/Caskroom/\(cask)" }
        guard caskroom.contains(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/install.sh | zsh"
        }
        return "brew upgrade --cask \(cask)"
    }

    // Capture the version this process loaded. The bundle at the same path may be replaced while
    // we run, but that does not change the Mach-O or version already resident in this process.
    static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

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
        watchForInstalledReplacement()
        Task {
            while true {
                let newer = await newerVersion()
                writeShellNotice(newer)
                if let newer {
                    await MainActor.run { NotchController.shared.showUpdate(newer) }
                }
                if let newer, UserDefaults.standard.string(forKey: "notifiedVersion") != newer {
                    UserDefaults.standard.set(newer, forKey: "notifiedVersion")
                    notify(newer)
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
                cached = nil   // so the next round actually asks GitHub again
            }
        }
    }

    /// Reopens the app when Homebrew (or install.sh) replaces its bundle with a newer version.
    ///
    /// A process keeps executing the old Mach-O after the file on disk is replaced, so merely
    /// finishing `brew upgrade` cannot change the version already in memory. Poll the stable
    /// bundle location and hand reopening to a tiny helper that waits until this process has
    /// completely exited. Waiting matters: a plain `open` while this instance is alive only
    /// activates the old instance instead of launching the new executable.
    private static func watchForInstalledReplacement() {
        Task.detached(priority: .utility) {
            let bundle = URL(fileURLWithPath: stableBundlePath())
            while true {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }

                guard let installed = installedVersion(at: bundle),
                      isNewer(installed, than: current),
                      scheduleReopen(of: bundle)
                else { continue }
                return
            }
        }
    }

    /// Version physically present at a bundle URL, rather than the version cached by Bundle.main.
    static func installedVersion(at bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let executable = info["CFBundleExecutable"] as? String,
              FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { return nil }
        return version
    }

    /// Starts a helper which waits for this instance to exit, then opens the new bundle.
    private static func scheduleReopen(of bundle: URL) -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while kill -0 \"$0\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$1\"",
            "\(ProcessInfo.processInfo.processIdentifier)",
            bundle.path,
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        guard (try? helper.run()) != nil else { return false }

        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // ponytail: UNUserNotificationCenter asks the system for a bundle id and traps without one,
    //           which is exactly how `swift run` runs it. No bundle, no banner.
    private static func notify(_ version: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Creo \(version) is out"
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
        let line = "[creo] \(version) is out (you have \(current)) — \(upgradeCommand)\n"
        try? FileManager.default.createDirectory(at: noticeFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? line.write(to: noticeFile, atomically: true, encoding: .utf8)
    }

    /// Adds the two lines that print it, once, keeping a copy of the file as it was.
    static func installShellNotice() {
        let zshrc = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zshrc")
        let marker = "# creo update notice"
        let original = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        var existing = original
        if existing.contains("# claude-sessions update notice") {
            existing = existing.split(separator: "\n", omittingEmptySubsequences: false)
                .filter {
                    !$0.contains("# claude-sessions update notice")
                        && !$0.contains("Application Support/ClaudeSessions/update-notice")
                }
                .joined(separator: "\n")
        }
        guard !existing.contains(marker) else { return }

        if !original.isEmpty {   // never touch someone's shell setup without leaving a way back
            try? original.write(to: zshrc.appendingPathExtension("creo-backup"),
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
