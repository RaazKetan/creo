import SwiftUI
import ServiceManagement

/// Brings an already-running session forward, or starts it in the default terminal.
// ponytail: skipPermissions is opt-in and off by default. It hands the session blanket
//           tool approval, which is the user's call to make, not an install-time default.
func resume(_ s: Session, skipPermissions: Bool = false) {
    if focusRunningSession(s) { return }

    let quoted = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
    // Explain the two ways this can fail, instead of leaving a bare "command not found".
    let script = """
        #!/bin/zsh
        cd \(quoted) 2>/dev/null || {
          echo "That folder is gone: \(s.cwd)"
          read "?Press return to close… "
          exit 1
        }
        if ! command -v \(s.agent.binary) >/dev/null 2>&1; then
          echo "'\(s.agent.binary)' isn't installed, or isn't on your PATH."
          echo "Install it from \(s.agent.installURL), then try again."
          echo
          read "?Press return to close… "
          exit 1
        fi
        \(s.agent.resumeCommand(s.sessionID, skipPermissions: skipPermissions))

        """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(s.sessionID).command")
    try? script.write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

    // ponytail: hand the script to a terminal by name rather than to whatever claims `.command`.
    //           That association is not always a terminal — pointed at a coding agent, the script
    //           is read as a prompt, and you get a new session named after the file instead of
    //           the one you asked to resume.
    let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
    let isTerminal = terminalBundleIDs.contains(handler.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "")
    NSWorkspace.shared.open([url],
                            withApplicationAt: isTerminal ? handler! : URL(fileURLWithPath: fallbackTerminal),
                            configuration: NSWorkspace.OpenConfiguration())
}

private let fallbackTerminal = "/System/Applications/Utilities/Terminal.app"
private let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
    "com.github.wez.wezterm", "org.alacritty", "dev.warp.Warp-Stable", "co.zeit.hyper",
]

/// tty of the agent running this session, or nil if it isn't running — or if we
/// can't tell which of several sessions in the folder is the one on screen.
func runningSessionTTY(_ s: Session) -> String? {
    // Exact: the agent itself says which process is on this session.
    if let pid = runningSessions()[s.sessionID] { return tty(ofPID: "\(pid)") }

    // A folder match only identifies the session when the folder holds exactly one.
    // Guessing between siblings would surface the wrong window.
    guard s.aloneInFolder else { return nil }
    let quoted = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return tty(ofPID: """
        $(for pid in $(pgrep -x \(s.agent.binary)); do
            if [ "$(lsof -a -p $pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = \(quoted) ]; then
              echo $pid; break
            fi
          done)
        """)
}

private func tty(ofPID pid: String) -> String? {
    let tty = sh("ps -o tty= -p \(pid) 2>/dev/null | tr -d ' '")
    guard let tty, !tty.isEmpty, tty != "??" else { return nil }
    return "/dev/" + tty
}

/// Bundle path with any Homebrew version baked out of it:
/// …/Cellar/claude-session-manager/1.3.1/X.app → …/opt/claude-session-manager/X.app
func stableBundlePath() -> String {
    let path = Bundle.main.bundleURL.path
    guard let range = path.range(of: "/Cellar/[^/]+/[^/]+/", options: .regularExpression) else { return path }
    let formula = path[range].split(separator: "/")[1]
    return path.replacingCharacters(in: range, with: "/opt/\(formula)/")
}

/// Starts the app at login.
// ponytail: SMAppService records the bundle's literal path, which under a Homebrew formula
//           is a versioned Cellar directory that `brew upgrade` deletes — leaving a login
//           item pointing at nothing. Our own agent can name the stable symlink instead.
func enableLaunchAtLogin() {
    try? SMAppService.mainApp.unregister()   // drop the Cellar-pinned entry older builds made

    let agents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    let plist: [String: Any] = [
        "Label": "dev.local.claudesessions",
        "ProgramArguments": ["\(stableBundlePath())/Contents/MacOS/ClaudeSessions"],
        "RunAtLoad": true,
    ]
    guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    else { return }
    try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try? data.write(to: agents.appendingPathComponent("dev.local.claudesessions.plist"), options: .atomic)
}

/// Focuses the window already running this session.
// ponytail: only Terminal and iTerm2 expose tty per tab. Any other terminal falls through to a new window.
func focusRunningSession(_ s: Session) -> Bool {
    guard let tty = runningSessionTTY(s) else { return false }
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

    if running.contains("com.apple.Terminal"), osascript("""
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "no"
        """) == "ok" { return true }

    if running.contains("com.googlecode.iterm2"), osascript("""
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with ss in sessions of t
                if tty of ss is "\(tty)" then
                  select ss
                  select t
                  select w
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "no"
        """) == "ok" { return true }

    return false
}

/// Asks before trashing, and reports failure.
// ponytail: NSAlert, not SwiftUI's .confirmationDialog. The menu bar panel closes the moment a
//           context-menu item is picked, which tears the view down before a SwiftUI dialog can
//           present — so it silently did nothing. An alert outlives the panel.
@MainActor
func confirmAndTrash(_ s: Session) -> Bool {
    NSApp.activate(ignoringOtherApps: true)   // an accessory app has to come forward to show it

    let alert = NSAlert()
    alert.alertStyle = .warning
    // A label like "(no prompt)" identifies nothing, so always spell out which session it is.
    alert.messageText = s.label == "(no prompt)"
        ? "Move this \(s.agent.label) session to the Trash?"
        : "Move “\(s.label)” to the Trash?"
    alert.informativeText = [
        "\(s.agent.label) · \(s.shortPath) · \(s.created.formatted(date: .abbreviated, time: .shortened))",
        s.isRunning ? "It is running right now." : nil,
        "The transcript goes to the Trash, so you can put it back.",
    ].compactMap { $0 }.joined(separator: "\n")
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return false }

    if trashSession(s) { return true }

    let failed = NSAlert()
    failed.alertStyle = .warning
    failed.messageText = "Couldn't move it to the Trash"
    failed.informativeText = "The file may be open or protected. Nothing was changed."
    failed.runModal()
    return false
}

/// Prompts for a custom session name. An empty name restores the title read from the transcript.
// Like the delete confirmation, this is an NSAlert because selecting a context-menu item closes
// the menu-bar panel before a SwiftUI sheet can be presented.
@MainActor
func promptToRename(_ s: Session) -> Bool {
    NSApp.activate(ignoringOtherApps: true)

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.stringValue = s.name ?? ""
    field.placeholderString = s.title

    let alert = NSAlert()
    alert.messageText = "Rename session"
    alert.informativeText = "Enter a custom name. Leave it empty to use the automatic title."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    Names.set(field.stringValue, for: s.sessionID)
    return true
}

// MARK: - UI

/// Menu bar mark, as a pixel grid — one row per line, `1` is a filled cell.
private let iconPixels = [
    "0011111111111100",
    "0011111111111100",
    "0011011111101100",
    "0011011111101100",
    "1111111111111111",
    "1111111111111111",
    "0011111111111100",
    "0011111111111100",
    "0001010000101000",
    "0001010000101000",
]

// ponytail: 1.5pt cells land on whole device pixels at 2x, so the sprite stays crisp
//           instead of smearing the way a scaled bitmap would.
let statusIcon: NSImage = {
    let cell: CGFloat = 1.25
    let cols = CGFloat(iconPixels[0].count), rows = CGFloat(iconPixels.count)

    let icon = NSImage(size: NSSize(width: cols * cell, height: rows * cell), flipped: false) { _ in
        NSColor.black.setFill()   // template images are an alpha mask; macOS supplies the colour
        for (r, row) in iconPixels.enumerated() {
            for (c, pixel) in row.enumerated() where pixel == "1" {
                // Grid runs top-down; the drawing origin is bottom-left.
                NSRect(x: CGFloat(c) * cell,
                       y: (rows - 1 - CGFloat(r)) * cell,
                       width: cell, height: cell).fill()
            }
        }
        return true
    }
    icon.isTemplate = true   // white on a dark menu bar, black on a light one
    return icon
}()

struct SessionList: View {
    @State private var sessions: [Session] = []
    @State private var loadingSessions = true
    @State private var query = ""
    @AppStorage("skipPermissions") private var skipPermissions = false
    @State private var hovered: String?
    @State private var insideMatches: [String: String] = [:]   // session id -> the passage that matched
    @State private var searchingInside = false
    @State private var updateAvailable: String?
    @State private var copiedUpgrade = false
    @AppStorage("agentFilterRaw") private var agentFilterRaw = ""
    @AppStorage("activeOnly") private var activeOnly = false
    private var agentFilter: Agent? {
        get { Agent(rawValue: agentFilterRaw) }
        nonmutating set { agentFilterRaw = newValue?.rawValue ?? "" }
    }

    /// Matches on the visible label and path, plus anything found inside the transcripts.
    var filtered: [Session] {
        sessions.filter { s in
            guard agentFilter == nil || s.agent == agentFilter else { return false }
            guard !activeOnly || s.isActive else { return false }
            guard !query.isEmpty else { return true }
            return (s.cwd + " " + s.label).localizedCaseInsensitiveContains(query)
                || insideMatches[s.sessionID] != nil
        }
    }

    /// How many sessions each agent has, on purpose not narrowed by the Active toggle or the
    /// search box.
    ///
    // ponytail: these counts also decide whether a pill is disabled. Narrowing them by Active
    //           made "All" read 1 of 15, and greyed out Codex whenever no Codex session happened
    //           to be active — stranding you on a filter with no way back to the other agent.
    func count(_ agent: Agent?) -> Int {
        agent == nil ? sessions.count : sessions.filter { $0.agent == agent }.count
    }

    /// Says which filter emptied the list, so it never just looks broken.
    var emptyReason: String {
        if loadingSessions { return "Loading sessions…" }
        if sessions.isEmpty { return "No sessions yet." }
        if !query.isEmpty { return searchingInside ? "Searching…" : "Nothing matches “\(query)”." }
        if activeOnly {
            return agentFilter.map { "No \($0.label) session is active right now." }
                ?? "Nothing is active right now."
        }
        return agentFilter.map { "No \($0.label) sessions." } ?? "No sessions."
    }

    var activeCount: Int {
        sessions.filter { $0.isActive && (agentFilter == nil || $0.agent == agentFilter) }.count
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search sessions and conversations", text: $query)
                .textFieldStyle(.roundedBorder)
                // Debounced, and .task(id:) cancels the previous scan when the query changes.
                .task(id: query) {
                    guard query.count >= 2 else { insideMatches = [:]; return }
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    searchingInside = true
                    let text = query
                    let hits: [String: String] = await Task.detached(priority: .userInitiated) {
                        sessionsContaining(text)
                    }.value
                    guard !Task.isCancelled else { return }
                    insideMatches = hits
                    searchingInside = false
                }

            HStack(spacing: 6) {
                ForEach([nil] + Agent.allCases.map { Optional($0) }, id: \.self) { agent in
                    let selected = agentFilter == agent
                    Button {
                        agentFilter = agent
                    } label: {
                        HStack(spacing: 4) {
                            Text(agent?.label ?? "All")
                            Text("\(count(agent))")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                        }
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(selected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(count(agent) == 0 && agent != nil)
                    .opacity(count(agent) == 0 && agent != nil ? 0.4 : 1)
                }
                Spacer()
                // The ones you are still in: running now, or written to within the hour.
                Button { activeOnly.toggle() } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(activeOnly ? AnyShapeStyle(.black.opacity(0.65)) : AnyShapeStyle(.green))
                            .frame(width: 5, height: 5)
                        Text("Active")
                        Text("\(activeCount)")
                            .foregroundStyle(activeOnly ? AnyShapeStyle(.black.opacity(0.55))
                                                        : AnyShapeStyle(.secondary))
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 11, weight: activeOnly ? .semibold : .regular))
                    // Filled green when it is on: the one filter that hides rows should be
                    // obvious at a glance, or an empty list looks like a broken app.
                    // Dark text, because white on system green is barely legible.
                    .foregroundStyle(activeOnly ? AnyShapeStyle(.black.opacity(0.85))
                                                : AnyShapeStyle(.primary))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(activeOnly ? AnyShapeStyle(Color.green) : AnyShapeStyle(.quaternary),
                                in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Nothing active means the filter has nothing to show; the newest rows are already
                // at the top of the list, which is where you look once everything is closed.
                .disabled(activeCount == 0 && !activeOnly)   // still clickable when it is how you got here
                .opacity(activeCount == 0 ? 0.4 : 1)
                .help("Only sessions running now or touched in the last hour")
            }

            ScrollView {
                if filtered.isEmpty {
                    Text(emptyReason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 28)
                }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { s in
                        Button { resume(s, skipPermissions: skipPermissions) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if s.isRunning {
                                        Circle().fill(.green).frame(width: 6, height: 6)
                                            .help("Running now")
                                    } else if s.isActive {
                                        // Nobody is on it this second, but you were, minutes ago.
                                        Circle().strokeBorder(.green, lineWidth: 1).frame(width: 6, height: 6)
                                            .help("Active in the last hour")
                                    }
                                    Text(s.label)
                                        .lineLimit(1)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(s.exists ? .primary : .secondary)
                                }

                                HStack(spacing: 6) {
                                    if agentFilter == nil {
                                        Text(s.agent.label)
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    }
                                    Text(s.shortPath)
                                        .lineLimit(1).truncationMode(.head)
                                    Text("·")
                                    Text(s.when)
                                    // Enough of the id to recognise it; the menu copies the whole thing.
                                    Text(s.sessionID.prefix(8))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                        .help(s.sessionID)
                                    if !s.exists {
                                        Text("folder missing")
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)

                                // What the search found inside the conversation, in its own words.
                                if let passage = insideMatches[s.sessionID], !query.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "text.magnifyingglass")
                                        Text(passage).lineLimit(1).truncationMode(.tail)
                                    }
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(hovered == s.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!s.exists)
                        .onHover { hovered = $0 ? s.id : (hovered == s.id ? nil : hovered) }
                        .contextMenu {
                            Button("Rename…") {
                                if promptToRename(s) {
                                    Task {
                                        sessions = await Task.detached(priority: .userInitiated) {
                                            loadSessions()
                                        }.value
                                    }
                                }
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) {
                                if confirmAndTrash(s) { sessions = loadSessions() }
                            }
                            Button("Copy session id") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(s.sessionID, forType: .string)
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.id)])
                            }
                        }
                        .help(s.exists ? """
                                         Resume — switches to its window if it is already open
                                         Started \(s.created.formatted(date: .abbreviated, time: .shortened))
                                         """
                                       : "That folder no longer exists")
                    }
                }
            }
            .frame(height: 360)

            Toggle("Skip permission prompts", isOn: $skipPermissions)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(skipPermissions ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Resume with --dangerously-skip-permissions, so the session never asks before running a tool")

            if let newer = updateAvailable {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Update.upgradeCommand, forType: .string)
                    copiedUpgrade = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle")
                        Text(copiedUpgrade ? "Copied — paste it in a terminal"
                                           : "Version \(newer) is out. Click to copy the upgrade command.")
                        Spacer()
                    }
                    .font(.caption)
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Update.upgradeCommand)
            }

            HStack {
                Text(searchingInside ? "searching…" : "\(filtered.count) sessions")
                    .font(.caption).foregroundStyle(.secondary)
                // Visible version, so "did the upgrade land?" is answerable at a glance.
                Text("v\(Update.current)")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.caption)
            }
        }
        .padding(10)
        .frame(width: 340)
        // Reading transcripts and inspecting live agent processes takes a noticeable fraction
        // of a second. Keep it off the main actor so clicking the menu-bar icon opens the panel
        // immediately, then fill in the rows when the scan finishes.
        .task {
            loadingSessions = true
            sessions = await Task.detached(priority: .userInitiated) { loadSessions() }.value
            loadingSessions = false
        }
        .task { updateAvailable = await Update.newerVersion() }
    }
}

@main
struct ClaudeSessionsApp: App {
    init() {
        // runnable check: `swift run ClaudeSessions --list`
        // runnable check: `swift run ClaudeSessions --search <text>`
        if let i = CommandLine.arguments.firstIndex(of: "--search"), i + 1 < CommandLine.arguments.count {
            let hits = sessionsContaining(CommandLine.arguments[i + 1])
            let rows = loadSessions().filter { hits[$0.sessionID] != nil }
            rows.forEach { print("\($0.agent.label)  \($0.label.prefix(40))\n    \(hits[$0.sessionID] ?? "")") }
            assert(rows.allSatisfy { !($0.label.isEmpty) }, "matched a session with no label")
            print("\(rows.count) of \(hits.count) matches are sessions you can open")
            exit(0)
        }
        if CommandLine.arguments.contains("--list") {
            let s = loadSessions()
            s.forEach { print("\($0.exists ? " " : "!")\($0.when)  \($0.cwd)  \($0.agent.label)  \($0.sessionID)  \($0.isRunning ? "[running] " : "")\($0.name == nil ? "" : "[named] ")\($0.label.prefix(50))") }
            assert(s.allSatisfy { !$0.cwd.isEmpty && !$0.id.isEmpty }, "parsed session missing cwd/id")
            print("\(s.count) sessions")
            exit(0)
        }
        // runnable check: `swift run ClaudeSessions --update`
        if CommandLine.arguments.contains("--update") {
            assert(Update.isNewer("1.10.0", than: "1.9.0") && !Update.isNewer("1.9.0", than: "1.10.0"),
                   "version compare is doing a string comparison")
            assert(!Update.isNewer(Update.current, than: Update.current), "a version is newer than itself")
            var latest: String?
            let done = DispatchSemaphore(value: 0)   // init() is not async; the check still asks GitHub
            // Detached: init() is main-actor bound, so an inherited Task would wait on the
            // very thread the semaphore is holding.
            Task.detached { latest = await Update.newerVersion(); done.signal() }
            done.wait()
            print("running \(Update.current), \(latest.map { "\($0) is out" } ?? "up to date")")
            print("upgrade with: \(Update.upgradeCommand)")
            print("shell notice: \(Update.noticeFile.path)")
            exit(0)
        }
        Statusline.installIfNeeded()
        enableLaunchAtLogin()
        Update.installShellNotice()
        Update.watch()
    }

    var body: some Scene {
        MenuBarExtra { SessionList() } label: { Image(nsImage: statusIcon) }
            .menuBarExtraStyle(.window)
    }
}
