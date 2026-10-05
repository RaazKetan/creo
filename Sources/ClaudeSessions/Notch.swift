import AppKit
import QuartzCore
import SwiftUI

struct UsageWindow {
    let remaining: Int
    let resetsAt: Date

    init?(_ value: [String: Any]?) {
        guard let value,
              let used = value["usedPercent"] as? Double,
              let reset = value["resetsAt"] as? TimeInterval else { return nil }
        remaining = max(0, min(100, Int((100 - used).rounded())))
        resetsAt = Date(timeIntervalSince1970: reset)
    }

    /// Claude's shape: `{"utilization": 17.0, "resets_at": "2026-10-07T12:59:59.75+00:00"}`.
    init?(claude value: [String: Any]?) {
        guard let value, let used = value["utilization"] as? Double,
              let stamp = value["resets_at"] as? String else { return nil }
        // Fractional seconds are optional, so drop them rather than juggle two formatters.
        let whole = stamp.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        guard let reset = ISO8601DateFormatter().date(from: whole) else { return nil }
        remaining = max(0, min(100, Int((100 - used).rounded())))
        resetsAt = reset
    }

    var tint: Color {
        if remaining < 20 { return .red }
        if remaining <= 50 { return Color(red: 1.0, green: 0.62, blue: 0.08) }
        return .green
    }
}

struct PlanUsage {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?

    init?(fiveHour: UsageWindow?, weekly: UsageWindow?) {
        guard fiveHour != nil || weekly != nil else { return nil }
        self.fiveHour = fiveHour
        self.weekly = weekly
    }

    init?(codex result: [String: Any]) {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        fiveHour = UsageWindow(limits["primary"] as? [String: Any])
        weekly = UsageWindow(limits["secondary"] as? [String: Any])
        guard fiveHour != nil || weekly != nil else { return nil }
    }

    /// Ask the user's signed-in Codex CLI for the same plan windows it displays itself.
    /// The child process reads its own credentials; this app never opens or stores them.
    static func readCodex() -> PlanUsage? {
        let paths = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map { "\($0)/codex" }
        guard let binary = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"creo","title":"Creo","version":"1.0.0"},"capabilities":{}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read","params":{}}"#,
        ].joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(requests.utf8))

        var pending = Data()
        while process.isRunning {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (object["id"] as? Int) == 2 else { continue }
                return (object["result"] as? [String: Any]).flatMap { PlanUsage(codex: $0) }
            }
        }
        return nil
    }

    /// The same windows Claude Code's `/usage` shows. Claude Code keeps its sign-in in the
    /// Keychain; `security` is already trusted to read that item, so there is no prompt.
    /// The token is used for this one request and never stored.
    static func readClaude() async -> PlanUsage? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var secret = Data()
        if (try? process.run()) != nil {
            secret = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
        }
        if secret.isEmpty {   // older installs keep it in a file instead
            secret = (try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json"))) ?? Data()
        }
        guard let credentials = (try? JSONSerialization.jsonObject(with: secret)) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                                 timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // ponytail: an expired token just reads as unavailable; Claude Code refreshes it next run.
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return PlanUsage(fiveHour: UsageWindow(claude: body["five_hour"] as? [String: Any]),
                         weekly: UsageWindow(claude: body["seven_day"] as? [String: Any]))
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var usage: [Service: PlanUsage] = [:]
    @Published var updateVersion: String?
    @Published var isUpdating = false
    @Published var updateFailure: String?
    @Published var refreshToken = 0
    @Published var selectedService: Service?
    @Published var detailOnLeft = false
    @Published var detailVisible = false
    @Published var expansion: CGFloat = 0

    /// The compact rail, taller while an update button sits under the services.
    var railHeight: CGFloat { updateVersion == nil ? 160 : 194 }
}

enum Service: String, CaseIterable {
    case chatgpt, claude, perplexity

    /// Services whose plan usage Creo can read locally.
    static let tracked: [Service] = [.chatgpt, .claude]

    var title: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .perplexity: "Perplexity"
        }
    }

    var mark: NSImage {
        let url = Bundle.module.url(forResource: rawValue, withExtension: "png")!
        return NSImage(contentsOf: url)!
    }

    var agent: Agent? {
        switch self {
        case .chatgpt: .codex
        case .claude: .claude
        case .perplexity: nil
        }
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).foregroundStyle(Color.primary.opacity(0.8))
                Spacer()
                Text("\(window.remaining)%")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("· \(window.resetsAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .foregroundStyle(Color.primary.opacity(0.55))
            }
            .font(.system(size: 10))
            GeometryReader { geometry in
                Capsule().fill(Color.primary.opacity(0.13))
                    .overlay(alignment: .leading) {
                        Capsule().fill(window.tint)
                            .frame(width: geometry.size.width * CGFloat(window.remaining) / 100)
                    }
            }
            .frame(height: 4)
            .animation(.easeOut(duration: 0.32), value: window.remaining)
            .accessibilityLabel("\(title), \(window.remaining) percent remaining")
        }
    }
}

/// Draw the dock at a stable position while the flyout grows around it.
/// Only this shape animates; the live panel never resizes mid-animation.
private struct NotchSilhouette: Shape {
    var expansion: CGFloat
    let detailOnLeft: Bool
    let railHeight: CGFloat

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(1, max(0, expansion))
        let right = 54 + 340 * progress
        let left: CGFloat = 40
        let rail = railHeight
        let bottom = rail + (392 - rail) * progress
        let topRadius = 18 + 4 * progress
        let lowerRadius = min(22, min((right - left) / 2, (bottom - rail) / 2))
        let insideRadius = min(12, (bottom - rail) / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: detailOnLeft ? rect.maxX - x : rect.minX + x,
                    y: rect.minY + y)
        }

        // One continuous outline avoids the ridge made by overlapping rounded
        // rectangles. The dock side remains stationary as the flyout unfolds.
        var path = Path()
        path.move(to: point(18, 0))
        path.addLine(to: point(right - topRadius, 0))
        path.addQuadCurve(to: point(right, topRadius), control: point(right, 0))
        path.addLine(to: point(right, bottom - lowerRadius))
        path.addQuadCurve(to: point(right - lowerRadius, bottom), control: point(right, bottom))
        path.addLine(to: point(left + lowerRadius, bottom))
        path.addQuadCurve(to: point(left, bottom - lowerRadius), control: point(left, bottom))
        path.addLine(to: point(left, rail + insideRadius))
        path.addQuadCurve(to: point(left - insideRadius, rail), control: point(left, rail))
        path.addLine(to: point(18, rail))
        path.addQuadCurve(to: point(0, rail - 18), control: point(0, rail))
        path.addLine(to: point(0, 18))
        path.addQuadCurve(to: point(18, 0), control: point(0, 0))
        path.closeSubpath()
        return path
    }
}

private struct NotchView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var state: NotchState
    let close: () -> Void
    let select: (Service) -> Void
    @State private var sessions: [Session] = []
    @State private var loading = true
    @State private var query = ""
    @State private var matches: [String: String] = [:]
    @State private var searching = false
    @State private var sessionFilter: Agent?
    @AppStorage("activeOnly") private var activeOnly = false
    @AppStorage("skipPermissions") private var skipPermissions = false

    private var surface: Color {
        colorScheme == .dark
            ? Color(red: 0.025, green: 0.027, blue: 0.032)
            : Color(red: 0.988, green: 0.980, blue: 0.958)
    }

    private var visibleSessions: [Session] {
        guard state.selectedService != .perplexity else { return [] }
        return sessions.filter { session in
            guard sessionFilter == nil || session.agent == sessionFilter else { return false }
            guard !activeOnly || session.isActive else { return false }
            guard !query.isEmpty else { return true }
            return (session.label + " " + session.cwd).localizedCaseInsensitiveContains(query)
                || matches[session.sessionID] != nil
        }
    }

    private func count(_ service: Service) -> Int {
        guard let agent = service.agent else { return 0 }
        return sessions.filter { $0.agent == agent }.count
    }

    private func usageHint(_ service: Service) -> String {
        guard Service.tracked.contains(service) else { return "\(service.title) usage opens in your account" }
        let windows: [String] = [
            state.usage[service]?.fiveHour.map { "\($0.remaining)% 5h remaining" },
            state.usage[service]?.weekly.map { "\($0.remaining)% weekly remaining" },
        ].compactMap { $0 }
        return windows.isEmpty ? "\(service.title) usage unavailable" : windows.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if state.detailOnLeft, let selected = state.selectedService {
                detailPanel(for: selected)
                    .opacity(state.detailVisible ? 1 : 0)
                    .offset(x: state.detailVisible ? 0 : 6)
                    .allowsHitTesting(state.detailVisible)
            }
            serviceRail
            if !state.detailOnLeft, let selected = state.selectedService {
                detailPanel(for: selected)
                    .opacity(state.detailVisible ? 1 : 0)
                    .offset(x: state.detailVisible ? 0 : -6)
                    .allowsHitTesting(state.detailVisible)
            }
        }
        .frame(width: state.selectedService == nil ? 54 : 394,
               height: state.selectedService == nil ? state.railHeight : 392,
               alignment: .topLeading)
        .background {
            NotchSilhouette(expansion: state.expansion,
                            detailOnLeft: state.detailOnLeft,
                            railHeight: state.railHeight)
                .fill(surface)
                .overlay {
                    NotchSilhouette(expansion: state.expansion,
                                    detailOnLeft: state.detailOnLeft,
                                    railHeight: state.railHeight)
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.12),
                                lineWidth: 1)
                }
        }
        .clipShape(NotchSilhouette(expansion: state.expansion,
                                   detailOnLeft: state.detailOnLeft,
                                   railHeight: state.railHeight))
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: state.detailOnLeft ? .topTrailing : .topLeading)
        .task(id: state.refreshToken) {
            loading = true
            sessions = await Task.detached(priority: .userInitiated) { loadSessions() }.value
            loading = false
        }
        .onChange(of: state.selectedService) { service in
            sessionFilter = service?.agent
        }
        .animation(.easeInOut(duration: 0.2), value: colorScheme)
    }

    private func detailPanel(for selected: Service) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: selected.mark)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
                Text(selected.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let version = state.updateVersion {
                    Button { startUpdate(version) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: state.isUpdating
                                  ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                            Text(state.isUpdating ? "Updating…"
                                 : state.updateFailure == nil ? "Update \(version)" : "Retry update")
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(state.updateFailure == nil ? .green : .orange)
                        .padding(.horizontal, 7)
                        .frame(height: 24)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isUpdating)
                    .help(state.updateFailure ?? "Install the update automatically and reopen Creo")
                }
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.65))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 42)

            usageSection(for: selected)
                .frame(height: 80)
                .padding(.horizontal, 12)

            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.primary.opacity(0.55))
                TextField("Search sessions and conversations", text: $query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .font(.system(size: 11))
                    .task(id: query) {
                        guard query.count >= 2 else { matches = [:]; searching = false; return }
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
                        searching = true
                        let text = query
                        let hits = await Task.detached(priority: .userInitiated) {
                            sessionsContaining(text)
                        }.value
                        guard !Task.isCancelled else { return }
                        matches = hits
                        searching = false
                    }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.primary.opacity(0.085), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 6)

            HStack(spacing: 8) {
                Text(searching ? "Searching…" : "\(visibleSessions.count) sessions")
                    .frame(minWidth: 58, alignment: .leading)
                if selected != .perplexity {
                    filterButton("All", agent: nil)
                    filterButton("ChatGPT", agent: .codex)
                    filterButton("Claude", agent: .claude)
                }
                Spacer(minLength: 0)
                if selected != .perplexity {
                    Button { activeOnly.toggle() } label: {
                        Label("Active", systemImage: activeOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(activeOnly ? Color.green : Color.primary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.primary.opacity(0.6))
            .padding(.horizontal, 13)
            .frame(height: 24)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if visibleSessions.isEmpty { emptyState }
                    ForEach(visibleSessions) { session in sessionRow(session) }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 176)

            Divider().overlay(Color.primary.opacity(0.17))
                .padding(.horizontal, 14)
            HStack(spacing: 10) {
                Text("Right-click a session for options")
                    .foregroundStyle(Color.primary.opacity(0.4))
                Spacer(minLength: 0)
                Text("v\(Update.current)")
                    .foregroundStyle(Color.primary.opacity(0.4))
                Menu {
                    Toggle("Run without approval prompts", isOn: $skipPermissions)
                        .help("Applies to Claude and Codex. Codex sandbox limits still apply.")
                    Divider()
                    Button("Quit Creo") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.09), in: Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("Settings")
                .help("Settings")
                .frame(width: 22)
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.primary.opacity(0.65))
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: 340, height: 392)
    }

    private func startUpdate(_ version: String) {
        guard !state.isUpdating else { return }
        state.isUpdating = true
        state.updateFailure = nil
        Task {
            if let failure = await Update.install(version) {
                state.isUpdating = false
                state.updateFailure = failure
            }
        }
    }

    private var serviceRail: some View {
        VStack(spacing: 6) {
            ForEach(Service.allCases, id: \.self) { service in
                serviceButton(service)
            }
            if let version = state.updateVersion {
                Button { startUpdate(version) } label: {
                    Image(systemName: state.isUpdating ? "arrow.triangle.2.circlepath"
                          : "arrow.down.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(state.updateFailure == nil ? .green : .orange)
                        .frame(width: 42, height: 26)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(state.isUpdating)
                .help(state.updateFailure ?? "Update to Creo \(version)")
                .accessibilityLabel("Update to Creo \(version)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func serviceButton(_ service: Service) -> some View {
        Button { select(service) } label: {
            ZStack {
                Circle().stroke(
                    Color.primary.opacity(state.selectedService == service ? 0.32 : 0.16),
                    lineWidth: 2
                )
                if let usage = state.usage[service] {
                    usageRings(usage)
                }
                Image(nsImage: service.mark)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)
            }
            .frame(width: 42, height: 42)
            .contentShape(Circle())
            .scaleEffect(state.selectedService == service ? 1.04 : 1)
            .animation(.easeOut(duration: 0.18), value: state.selectedService)
            .animation(.easeOut(duration: 0.32), value: state.usage[service]?.fiveHour?.remaining)
            .animation(.easeOut(duration: 0.32), value: state.usage[service]?.weekly?.remaining)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(service.title), \(count(service)) sessions, \(usageHint(service))")
        .help("\(service.title): \(usageHint(service))")
    }

    @ViewBuilder
    private func usageRings(_ usage: PlanUsage) -> some View {
        // The short allowance is the primary signal, so it owns the larger,
        // easier-to-read outer ring. The longer weekly allowance sits inside.
        if let fiveHour = usage.fiveHour {
            Circle().trim(from: 0, to: CGFloat(fiveHour.remaining) / 100)
                .stroke(fiveHour.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        if let weekly = usage.weekly {
            Circle().trim(from: 0, to: CGFloat(weekly.remaining) / 100)
                .stroke(weekly.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(4)
        }
    }

    @ViewBuilder
    private func usageSection(for selected: Service) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Usage remaining")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if Service.tracked.contains(selected) {
                    Button {
                        NotchController.shared.refreshUsage()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Refresh usage")
                }
            }
            if Service.tracked.contains(selected) {
                if let window = state.usage[selected]?.fiveHour { UsageBar(title: "5h", window: window) }
                if let window = state.usage[selected]?.weekly { UsageBar(title: "Weekly", window: window) }
                if state.usage[selected] == nil {
                    Text("Sign in to \(selected == .claude ? "Claude Code" : "Codex") to see usage here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
            } else {
                Text("Perplexity usage is available in your account.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.6))
                Link("Open \(selected.title) usage ↗", destination:
                        URL(string: "https://www.perplexity.ai/settings/account")!)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 20))
            Text(loading ? "Loading sessions…" :
                 state.selectedService == .perplexity ? "No local Perplexity sessions" :
                 query.isEmpty ? "No sessions here" : "No matching sessions")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(Color.primary.opacity(0.55))
        .frame(maxWidth: .infinity)
        .padding(.top, 55)
    }

    private func filterButton(_ label: String, agent: Agent?) -> some View {
        Button { sessionFilter = agent } label: {
            Text(label)
                .foregroundStyle(sessionFilter == agent ? Color.primary : Color.primary.opacity(0.55))
                .fontWeight(sessionFilter == agent ? .semibold : .regular)
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: Session) -> some View {
        Button {
            resume(session, skipPermissions: skipPermissions)
            close()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(session.isRunning ? Color.green : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(session.label)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.when)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.48))
                }
                Text(session.shortPath)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.primary.opacity(0.53))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let passage = matches[session.sessionID], !query.isEmpty {
                    Text(passage)
                        .font(.system(size: 10))
                        .foregroundStyle(.green.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(session.exists ? Color.primary : Color.primary.opacity(0.45))
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.075 : 0.055),
                        in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(!session.exists)
        .contextMenu {
            Button("Rename…") {
                if promptToRename(session) { state.refreshToken += 1 }
            }
            Button("Move to Trash…", role: .destructive) {
                if confirmAndTrash(session) { state.refreshToken += 1 }
            }
            Button("Copy session id") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.sessionID, forType: .string)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.id)])
            }
        }
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchController {
    static let shared = NotchController()
    weak var statusButton: NSStatusBarButton?
    private let state = NotchState()
    private var panel: NotchPanel?
    private var outsideClickMonitors: [Any] = []
    private var animationID = 0
    private var isHiding = false
    private var targetExpanded = false

    func start() {
        guard panel == nil, let screen = statusButton?.window?.screen ?? NSScreen.main else { return }
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(state: state, close: { [weak self] in
            self?.hide()
        }, select: { [weak self] service in
            self?.select(service)
        }))
        self.panel = panel
        position(on: screen)
        refreshUsage()
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5 * 60))
                refreshUsage()
            }
        }
    }

    func toggle() {
        if panel?.isVisible == true && !isHiding { hide() } else { show() }
    }

    func show() {
        if panel == nil { start() }
        guard let panel, let screen = statusButton?.window?.screen ?? NSScreen.main else { return }
        animationID += 1
        let currentAnimation = animationID
        isHiding = false
        targetExpanded = false
        state.selectedService = nil
        state.detailVisible = false
        state.expansion = 0
        position(on: screen)
        let target = panel.frame
        // Keep the hosting view at its real size throughout the fade. Resizing
        // during a click made SwiftUI relayout buttons and occasionally blanked
        // the flyout after quick provider switches.
        panel.setFrame(target, display: false)
        panel.alphaValue = 0
        state.refreshToken += 1
        // Ask again on every open (cached for a minute), so a release published while the app
        // was running shows up now instead of at the next six-hour check.
        Task { if let newer = await Update.newerVersion() { showUpdate(newer) } }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, self.animationID == currentAnimation else { return }
                panel?.setFrame(target, display: true)
                panel?.alphaValue = 1
            }
        }
        if outsideClickMonitors.isEmpty {
            if let monitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown],
                handler: { [weak self] _ in
                    Task { @MainActor in self?.dismissIfClickIsOutside() }
                }) {
                outsideClickMonitors.append(monitor)
            }
            if let monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown],
                handler: { [weak self] event in
                    Task { @MainActor in self?.dismissIfClickIsOutside() }
                    return event
                }) {
                outsideClickMonitors.append(monitor)
            }
        }
    }

    func hide() {
        animationID += 1
        let currentAnimation = animationID
        isHiding = true
        targetExpanded = false
        if let panel, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, self.animationID == currentAnimation else { return }
                    panel?.orderOut(nil)
                    panel?.alphaValue = 1
                    self.isHiding = false
                }
            }
        }
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    func showUpdate(_ version: String) {
        guard state.updateVersion != version else { return }
        state.updateVersion = version
        updateStatusIcon()
        // The rail just grew; resize a visible compact panel to fit the button.
        if let panel, panel.isVisible, !targetExpanded, let screen = panel.screen ?? NSScreen.main {
            position(on: screen)
        }
    }

    private func dismissIfClickIsOutside() {
        let point = NSEvent.mouseLocation
        if statusButtonFrame()?.contains(point) == true { return }
        if panel?.frame.contains(point) == true { return }
        hide()
    }

    private func select(_ service: Service) {
        guard let screen = statusButton?.window?.screen ?? panel?.screen ?? NSScreen.main else { return }
        animationID += 1
        let currentAnimation = animationID
        if !targetExpanded {
            targetExpanded = true
            // A collapsing flyout already has a full-size panel. Reversing its
            // shape animation avoids a frame jump on fast repeated clicks.
            let reversing = state.selectedService != nil
            if !reversing {
                let dockX = dockOrigin(on: screen)
                state.detailOnLeft = dockX + 394 > screen.visibleFrame.maxX - 8
                state.detailVisible = false
                state.expansion = 0
                // Grow only the transparent window first. The compact rail is
                // already aligned to its final screen position, so no SwiftUI
                // content is relaid out inside a changing AppKit frame.
                panel?.setFrame(frame(on: screen, expanded: true), display: true)
            } else {
                state.selectedService = service
            }
            panel?.makeKeyAndOrderFront(nil)
            Task { @MainActor [weak self] in
                if !reversing {
                    try? await Task.sleep(for: .milliseconds(16))
                    guard let self, self.animationID == currentAnimation else { return }
                    self.state.selectedService = service
                    // Mount the detail view invisibly before its silhouette
                    // starts moving; this avoids the first-frame content snap.
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard let self, self.animationID == currentAnimation else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    self.state.expansion = 1
                }
                try? await Task.sleep(for: .milliseconds(reversing ? 0 : 90))
                guard self.animationID == currentAnimation else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    self.state.detailVisible = true
                }
            }
        } else if state.selectedService == service {
            targetExpanded = false
            // A fixed-duration curve has a known end. The old spring could
            // still be settling when the transparent panel was compacted,
            // visibly chopping off its last few frames.
            withAnimation(.timingCurve(0.24, 0.72, 0.2, 1, duration: 0.28)) {
                state.detailVisible = false
                state.expansion = 0
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(310))
                guard let self, self.animationID == currentAnimation else { return }
                self.state.selectedService = nil
                try? await Task.sleep(for: .milliseconds(16))
                guard self.animationID == currentAnimation else { return }
                self.position(on: screen)
            }
        } else {
            withAnimation(.easeIn(duration: 0.09)) { state.detailVisible = false }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, self.animationID == currentAnimation else { return }
                self.state.selectedService = service
                withAnimation(.easeOut(duration: 0.18)) { self.state.detailVisible = true }
            }
        }
    }

    func refreshUsage() {
        Task.detached(priority: .utility) {
            async let codex = PlanUsage.readCodex()
            async let claude = PlanUsage.readClaude()
            let results: [(Service, PlanUsage?)] = [(.chatgpt, await codex), (.claude, await claude)]
            await MainActor.run {
                // A failed read keeps the last good value instead of blanking the ring.
                for case let (service, usage?) in results { self.state.usage[service] = usage }
                self.updateStatusIcon()
            }
        }
    }

    /// The icon stays the plain menu-bar template; low plans are named in its tooltip.
    private func updateStatusIcon() {
        guard let button = statusButton else { return }
        button.image = state.updateVersion == nil ? statusIcon : badgedStatusIcon
        button.imageScaling = .scaleProportionallyDown
        let critical = Service.tracked.flatMap { service in
            [("5h", state.usage[service]?.fiveHour), ("Weekly", state.usage[service]?.weekly)]
                .compactMap { name, window -> String? in
                    guard let window, window.remaining < 20, window.resetsAt > Date() else { return nil }
                    return "\(service.title) \(name) \(window.remaining)% remaining"
                }
        }
        let update = state.updateVersion.map { ["Update \($0) available"] } ?? []
        button.toolTip = (["Creo — sessions and usage"] + update + critical).joined(separator: " · ")
    }

    private func position(on screen: NSScreen) {
        guard let panel else { return }
        panel.setFrame(frame(on: screen, expanded: state.selectedService != nil), display: true)
    }

    private func frame(on screen: NSScreen, expanded: Bool) -> NSRect {
        let width: CGFloat = expanded ? 394 : 54
        let height: CGFloat = expanded ? 392 : state.railHeight
        let dockX = dockOrigin(on: screen)
        let preferredX = expanded && state.detailOnLeft ? dockX - 340 : dockX
        let x = min(max(preferredX, screen.visibleFrame.minX + 8),
                    screen.visibleFrame.maxX - width - 8)
        let top = statusButtonFrame()?.minY ?? screen.visibleFrame.maxY
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    private func statusButtonFrame() -> NSRect? {
        guard let button = statusButton, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func dockOrigin(on screen: NSScreen) -> CGFloat {
        let anchor = statusButtonFrame()?.midX ?? screen.visibleFrame.midX
        return min(max(anchor - 27, screen.visibleFrame.minX + 8),
                   screen.visibleFrame.maxX - 54 - 8)
    }
}
