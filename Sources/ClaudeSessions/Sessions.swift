import Foundation

// MARK: - Model

/// The coding agent a session belongs to. Each stores its transcripts differently and has
/// its own resume command, but a row is a row.
enum Agent: String, CaseIterable {
    case claude, codex

    var label: String { self == .claude ? "Claude" : "Codex" }
    var binary: String { rawValue }
    var installURL: String {
        self == .claude ? "https://claude.com/claude-code" : "https://developers.openai.com/codex/cli"
    }

    /// Resume command, minus the working directory.
    func resumeCommand(_ id: String, skipPermissions: Bool) -> String {
        switch self {
        case .claude: return "claude --resume \(id)" + (skipPermissions ? " --dangerously-skip-permissions" : "")
        case .codex:  return "codex resume \(id)" + (skipPermissions ? " --ask-for-approval never" : "")
        }
    }
}

struct Session: Identifiable {
    /// The log file's path. Unique per row — the same session id can legitimately exist
    /// under two project folders, and SwiftUI needs the rows to be distinguishable.
    let id: String
    /// What the resume command takes. Shared between copies of the same conversation.
    let sessionID: String
    let agent: Agent
    let cwd: String
    let title: String      // auto-derived from the first usable prompt
    let name: String?      // user-chosen label, wins over title
    let created: Date
    let modified: Date
    let exists: Bool
    /// True when this is the only session in its folder, so a folder match identifies it.
    var aloneInFolder = false
    /// An agent process is on this session right now.
    var isRunning = false

    /// Path with the home directory collapsed, the way a shell prompt shows it.
    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return cwd == home ? "~" : cwd.replacingOccurrences(of: home + "/", with: "~/")
    }

    /// When you were last in it — "3m ago" for today, "Yesterday", "Aug 9" beyond that.
    ///
    // ponytail: last activity, not creation date. The list is ordered by it, so labelling rows
    //           with the day they were started put a session you worked on this morning at the
    //           top of the list wearing a date from three weeks ago.
    var when: String {
        let days = Calendar.current.dateComponents([.day], from: modified, to: Date()).day ?? 0
        if days == 0 {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: modified, relativeTo: Date())
        }
        if days == 1 { return "Yesterday" }
        return modified.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Running now, or touched within the hour — the sessions you are likely still in.
    var isActive: Bool { isRunning || modified.timeIntervalSinceNow > -3600 }

    var label: String { name ?? title }
    var project: String { (cwd as NSString).lastPathComponent }
}

/// Runs a command in a login shell so PATH matches the user's terminal.
@discardableResult
func sh(_ command: String) -> String? { run("/bin/zsh", ["-lc", command]) }

func osascript(_ source: String) -> String? { run("/usr/bin/osascript", ["-e", source]) }

private func run(_ tool: String, _ arguments: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Turns a project folder name back into a path, using the filesystem to settle ambiguity.
///
/// Claude Code encodes the directory by replacing `/` with `-`, which is lossy: for
/// `-Users-me-CODE-hr-match` you cannot tell which dashes were slashes. So walk the tokens and
/// keep extending the current component until the result is a directory that exists.
/// Returns nil when nothing matches — the project was moved or deleted.
func decodeProjectFolder(_ encoded: String) -> String? {
    let tokens = encoded.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
    guard !tokens.isEmpty else { return nil }

    var path = ""
    var pending = ""
    for token in tokens {
        pending = pending.isEmpty ? token : pending + "-" + token
        var isDir: ObjCBool = false
        let candidate = path + "/" + pending
        if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
            path = candidate
            pending = ""
        }
    }
    return pending.isEmpty ? path : nil
}

/// Moves a session's transcript to the Trash, along with any subagent logs it spawned.
///
// ponytail: trashItem, never unlink. These files are unrecoverable conversations, some of them
//           hundreds of megabytes, and the Trash is the difference between a mistake and a loss.
func trashSession(_ s: Session) -> Bool {
    let fm = FileManager.default
    let transcript = URL(fileURLWithPath: s.id)

    // Claude Code keeps subagent transcripts in a folder named after the session, next to it.
    var targets = [transcript]
    let subagents = transcript.deletingLastPathComponent().appendingPathComponent(s.sessionID)
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: subagents.path, isDirectory: &isDir), isDir.boolValue {
        targets.append(subagents)
    }

    for target in targets {
        guard (try? fm.trashItem(at: target, resultingItemURL: nil)) != nil else { return false }
    }
    Names.set("", for: s.sessionID)   // forget any custom name we were keeping for it
    return true
}

/// Sessions whose transcript contains `text`, each with the passage it turned up in.
///
// ponytail: ask grep only for the byte offset of the hit and read the window around it here.
//           Asking grep itself for context — a regex with `.{0,40}` either side — took over two
//           minutes on the same corpus. Not ripgrep: most Macs do not have it, and one grep per
//           file across the cores gets 733MB down to ~1.3s anyway, from 7.5s serial.
func sessionsContaining(_ text: String) -> [String: String] {
    let quoted = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let roots = [".claude/projects", ".codex/sessions"]
        .map { "'" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path + "'" }
        .joined(separator: " ")
    // -b with -o gives the offset of the match itself; -m 1 stops at the first line holding one,
    // and `head -1` keeps a line with many hits from spilling a non-atomic write into the pipe.
    let command = """
        find \(roots) -name '*.jsonl' -print0 2>/dev/null \
          | xargs -0 -P 12 -n 1 /bin/sh -c 'grep -boFim 1 -H -e "$0" "$1" 2>/dev/null | head -1' \(quoted)
        """
    guard let out = sh(command), !out.isEmpty else { return [:] }

    // A hit is either <folder>/<session-id>.jsonl or, for a subagent transcript,
    // <folder>/<session-id>/subagents/agent-*.jsonl — and a Codex rollout can belong to a
    // subagent thread. Either way the row you can open is the conversation that spawned it.
    let parents = codexThreads().parents
    var found: [String: String] = [:]
    for line in out.split(separator: "\n") {
        // "<path>:<byte offset>:<match>" — split on the extension, paths can hold colons.
        let row = String(line)
        guard let cut = row.range(of: ".jsonl:"),
              let offset = Int(row[cut.upperBound...].prefix(while: \.isNumber)),
              let matched = firstSessionID(in: String(row[..<cut.lowerBound])) else { continue }
        let id = parents[matched] ?? matched
        if found[id] == nil {
            found[id] = passage(in: String(row[..<cut.upperBound].dropLast()), around: offset)
        }
    }
    return found
}

/// The text either side of a hit, read straight out of the transcript.
private func passage(in path: String, around offset: Int) -> String {
    guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(max(0, offset - 40)))
    guard let data = try? handle.read(upToCount: 160) else { return "" }
    return readable(String(decoding: data, as: UTF8.self))
}

/// A line of raw transcript, made fit to read: JSON escapes undone, runs of space collapsed.
private func readable(_ s: String) -> String {
    s.replacingOccurrences(of: "\\n", with: " ")
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The first session id inside a string — a path, a command line — or nil.
private let uuidPattern = try? NSRegularExpression(
    pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

func firstSessionID(in s: String) -> String? {
    guard let m = uuidPattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          let r = Range(m.range, in: s) else { return nil }
    return String(s[r])
}

/// Live sessions, id -> the process running each one.
///
// ponytail: ask the agents where they are instead of reading their command lines. A session
//           started by hand — `claude` in an editor's terminal, or a resume picked from the
//           agent's own menu — never names its id in argv, so argv matching only ever lit up
//           the sessions this app launched itself.
func runningSessions() -> [String: Int32] {
    var live: [String: Int32] = [:]

    // Claude Code keeps ~/.claude/sessions/<pid>.json for every live process, session id included.
    var claudeByPID: [Int32: String] = [:]
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["sessionId"] as? String,
              let pid = (obj["pid"] as? NSNumber)?.int32Value
        else { continue }
        claudeByPID[pid] = id
    }

    // Those files outlive a crash, so confirm a claude is still behind each pid — and matching on
    // the command keeps a recycled pid from lighting up somebody else's session.
    // ponytail: ps, not pgrep. pgrep hides the caller's own ancestors, so a session manager
    //           launched from a Claude session would miss that very session.
    for line in (sh("ps -Ao pid=,command=") ?? "").split(separator: "\n") {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let pid = Int32(text.prefix(while: \.isNumber)), text.contains("claude") else { continue }
        if let id = claudeByPID[pid] { live[id] = pid }
        // Versions predating those files still name the id when this app launched the resume.
        else if text.contains("--resume"), let id = firstSessionID(in: text) { live[id] = pid }
    }

    // Codex holds its rollout transcript open for as long as the session lives, so a codex
    // process's open files name its threads — itself, and any subagents it spawned.
    var pid: Int32 = 0
    for line in (sh("lsof -c codex -Fpn 2>/dev/null") ?? "").split(separator: "\n") {
        if line.hasPrefix("p") {
            pid = Int32(line.dropFirst()) ?? 0
        } else if line.hasPrefix("n"), line.contains("/rollout-"), let id = firstSessionID(in: String(line)) {
            live[id] = pid
        }
    }
    return live
}

/// User-chosen labels, keyed by session id.
// ponytail: one JSON file in Application Support — the widget reads the same path, so no App Group entitlement is needed.
enum Names {
    private static let root = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]
    static let url = root.appendingPathComponent("Creo/names.json")
    private static let legacyURL = root.appendingPathComponent("ClaudeSessions/names.json")

    static func load() -> [String: String] {
        if !FileManager.default.fileExists(atPath: url.path),
           let legacy = try? Data(contentsOf: legacyURL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? legacy.write(to: url, options: .atomic)
        }
        return (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func set(_ name: String, for id: String) {
        var all = load()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        all[id] = trimmed.isEmpty ? nil : trimmed   // clearing the field restores the auto summary
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all).write(to: url)
    }
}

/// First line of a user message, or nil if it's not worth showing as a title.
// ponytail: opening prompts are often junk — image-only, a slash command, a giant paste. Caller falls through to the next one.
func usableTitle(_ obj: [String: Any]) -> String? {
    let content = (obj["message"] as? [String: Any])?["content"]
    var text = ""
    if let s = content as? String {
        text = s
    } else if let blocks = content as? [[String: Any]] {
        text = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
    }
    return usableTitle(text)
}

/// The same judgement, for text that already came out of a message.
func usableTitle(_ text: String) -> String? {
    let junk = CharacterSet(charactersIn: "─━—-=_* ").union(.whitespacesAndNewlines)
    guard let line = text.split(separator: "\n").first?.trimmingCharacters(in: junk), line.count >= 3 else { return nil }
    guard !"<[/".contains(line.first!), !line.hasPrefix("Caveat:") else { return nil }
    guard !line.hasPrefix("# AGENTS.md") else { return nil }   // codex prepends this to the first turn
    guard line.count < 2000 else { return nil }  // a dumped file or stack trace, not a prompt
    return line.count > 160 ? line.prefix(160) + "…" : line
}

/// The start of a transcript, up to `limit` bytes.
// ponytail: String(decoding:) rather than String(data:encoding:) — the cut lands mid-character
//           often enough, and a nil there used to drop the whole session off the list.
func head(of file: URL, limit: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let chunk = try? handle.read(upToCount: limit) else { return nil }
    return String(decoding: chunk, as: UTF8.self)
}

/// Identity and title from the user messages at the top of a Claude transcript.
private func firstUserRecord(_ text: String, _ iso: ISO8601DateFormatter)
    -> (cwd: String, sid: String, created: Date, title: String?)? {
    var recordedCwd: String?, sid: String?, created = Date.distantPast, title: String?
    for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              obj["type"] as? String == "user",
              let c = obj["cwd"] as? String,
              let s = obj["sessionId"] as? String else { continue }

        if recordedCwd == nil {  // identity + creation time come from the first message, whatever it says
            (recordedCwd, sid) = (c, s)
            created = (obj["timestamp"] as? String).flatMap(iso.date(from:)) ?? .distantPast
        }
        title = usableTitle(obj)
        if title != nil { break }
    }
    guard let recordedCwd, let sid else { return nil }
    return (recordedCwd, sid, created, title)
}

/// Scans ~/.claude/projects/*/*.jsonl.
// ponytail: reads only the head of each file — cwd and the first user prompt are near the top.
func loadClaudeSessions() -> [Session] {
    let fm = FileManager.default
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let names = Names.load()

    var out: [Session] = []
    for dir in dirs {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            // 64KB covers nearly every session. A first prompt carrying a pasted image runs well
            // past it, and a record cut in half parses as nothing — so take a second, bigger bite
            // rather than leaving the session off the list altogether.
            var record: (cwd: String, sid: String, created: Date, title: String?)?
            for limit in [64 * 1024, 8 * 1024 * 1024] {
                guard let text = head(of: file, limit: limit) else { break }
                record = firstUserRecord(text, iso)
                if record != nil || text.utf8.count < limit { break }
            }
            guard let (recordedCwd, sid, created, title) = record else { continue }

            // The folder a session lives in beats the cwd written inside it. Copy a session
            // into another project and the file still names the directory it was born in.
            let folder = decodeProjectFolder(dir.lastPathComponent)
            let cwd = folder ?? recordedCwd

            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? created
            out.append(Session(id: file.path, sessionID: sid, agent: .claude, cwd: cwd,
                               title: title ?? "(no prompt)", name: names[sid],
                               created: created, modified: modified,
                               exists: fm.fileExists(atPath: cwd)))
        }
    }
    return out
}

/// What Codex calls each thread, and which threads are subagents rather than conversations.
///
// ponytail: shell out to sqlite3 rather than link SQLite — one read-only query, and the CLI ships
//           with macOS. `select *` so a schema that gains or loses a column still parses.
func codexThreads() -> (titles: [String: String], subagents: Set<String>, parents: [String: String]) {
    let out = sh("""
        db=$(ls -t ~/.codex/state_*.sqlite 2>/dev/null | head -1)
        [ -n "$db" ] && sqlite3 -readonly -json "$db" 'select * from threads' 2>/dev/null
        """) ?? ""
    guard let rows = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]]
    else { return ([:], [], [:]) }

    var titles: [String: String] = [:]
    var subagents: Set<String> = []
    var parents: [String: String] = [:]
    for row in rows {
        guard let id = row["id"] as? String else { continue }
        // A thread Codex spawned for itself is not a conversation you can carry on — it belongs
        // to the one that spawned it, which is where a search hit inside it should land.
        if row["thread_source"] as? String == "subagent" {
            subagents.insert(id)
            if let raw = (row["source"] as? String)?.data(using: .utf8),
               let source = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
               let spawn = (source["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any],
               let parent = spawn["parent_thread_id"] as? String {
                parents[id] = parent
            }
        }
        // The name the user gave it, else Codex's own summary, else what they opened with.
        if let title = ["name", "title", "first_user_message"]
            .compactMap({ (row[$0] as? String).flatMap(usableTitle) }).first {
            titles[id] = title
        }
    }
    return (titles, subagents, parents)
}

/// The first thing the user typed, if it is inside the chunk of the transcript we read.
func codexPrompt(_ text: String) -> String? {
    for line in text.split(separator: "\n") {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { continue }
        // Codex writes each turn twice: once as an event, once as the model's transcript item.
        var said: String?
        if payload["type"] as? String == "user_message" {
            said = payload["message"] as? String
        } else if payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] {
            said = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        if let title = said.flatMap(usableTitle) { return title }
    }
    return nil
}

/// Scans ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
///
/// Easier than Claude Code's layout: line one is a `session_meta` record carrying the id and
/// the working directory. Titles come from Codex's own thread record when it has one.
func loadCodexSessions() -> [Session] {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(".codex/sessions")
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return [] }

    let (titles, subagents, _) = codexThreads()

    // id -> thread name, e.g. "Explore project folder". Only ever held a handful of sessions,
    // and newer Codex versions stopped writing it, so it is a fallback and not the source.
    var threadNames: [String: String] = [:]
    if let index = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) {
        for line in index.split(separator: "\n") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let id = obj["id"] as? String, let name = obj["thread_name"] as? String {
                threadNames[id] = name
            }
        }
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let names = Names.load()

    var out: [Session] = []
    for case let file as URL in walker where file.lastPathComponent.hasPrefix("rollout-")
                                          && file.pathExtension == "jsonl" {
        guard let text = head(of: file, limit: 64 * 1024),
              let first = text.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String
        else { continue }
        guard !subagents.contains(id) else { continue }   // Codex's own helper threads, not sessions

        let created = (payload["timestamp"] as? String).flatMap(iso.date(from:)) ?? .distantPast
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? created

        let title = titles[id] ?? threadNames[id] ?? codexPrompt(text)
            ?? head(of: file, limit: 8 * 1024 * 1024).flatMap(codexPrompt) ?? "(untitled)"
        out.append(Session(id: file.path, sessionID: id, agent: .codex, cwd: cwd,
                           title: title, name: names[id],
                           created: created, modified: modified,
                           exists: fm.fileExists(atPath: cwd)))
    }
    return out
}

/// Every session from every agent, newest first.
func loadSessions() -> [Session] {
    var out = loadClaudeSessions() + loadCodexSessions()

    // Both passes are cross-agent: a folder holding one Claude session and three Codex ones is
    // not a folder where a cwd match identifies anything.
    var perFolder: [String: Int] = [:]
    for s in out { perFolder[s.cwd, default: 0] += 1 }
    let running = runningSessions()
    for i in out.indices {
        out[i].aloneInFolder = perFolder[out[i].cwd] == 1
        out[i].isRunning = running[out[i].sessionID] != nil
    }
    return out.sorted { $0.modified > $1.modified }
}
