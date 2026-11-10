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

    init(remaining: Int, resetsAt: Date) {
        self.remaining = remaining
        self.resetsAt = resetsAt
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

/// Why Claude's numbers are, or aren't, on screen. Being signed in and having a usable token
/// are different things: Claude Code only renews its token while it runs.
enum ClaudeRead {
    case usage(PlanUsage), signedOut, expired, rateLimited, unreachable

    var note: String? {
        switch self {
        case .usage: nil
        case .signedOut: "Sign in to Claude Code to see usage here."
        case .expired: "Claude Code's sign-in has expired. Run claude once to refresh usage."
        case .rateLimited: "Claude is limiting usage checks. Creo will retry shortly."
        case .unreachable: "Couldn't read Claude usage. Creo will retry."
        }
    }
}

struct PlanUsage {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    let plan: String?

    init?(fiveHour: UsageWindow?, weekly: UsageWindow?) {
        guard fiveHour != nil || weekly != nil else { return nil }
        self.fiveHour = fiveHour
        self.weekly = weekly
        plan = nil
    }

    /// "plus" reads "Plus". Older sign-ins still say "max" with a "_20x" tier, which is now Ultra.
    static func planName(_ type: String?, tier: String? = nil) -> String? {
        guard let type, !type.isEmpty else { return nil }
        return type == "max" && tier?.hasSuffix("_20x") == true ? "Ultra" : type.capitalized
    }

    /// The CLI's internal plan ids, grouped under the names people know. "pro", "prolite" and
    /// "promax" are all Pro. An id nobody has seen yet still shows, tidied: "pro_plus" reads
    /// "Pro Plus", so a new plan never needs a release to appear.
    static func codexPlanName(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        if type.hasPrefix("pro") { return "Pro" }
        if type.contains("business") { return "Business" }
        if type.hasPrefix("ent") { return "Enterprise" }
        if type.hasPrefix("edu") { return "Edu" }
        let words = type.replacingOccurrences(of: "_", with: " ").capitalized
        return words.count <= 16 ? words : nil   // a long internal id is noise, not a name
    }

    init?(codex result: [String: Any]) {
        guard let limits = result["rateLimits"] as? [String: Any] else { return nil }
        // A plan with no 5-hour limit can report its weekly window first, so go by each window's
        // length. Older CLIs don't send one: primary is then the short window, secondary the long.
        let first = limits["primary"] as? [String: Any], second = limits["secondary"] as? [String: Any]
        func isLong(_ window: [String: Any]?) -> Bool? { (window?["windowDurationMins"] as? Double).map { $0 >= 24 * 60 } }
        let firstLong = isLong(first) ?? false, secondLong = isLong(second) ?? true
        fiveHour = UsageWindow(!firstLong ? first : !secondLong ? second : nil)
        weekly = UsageWindow(firstLong ? first : secondLong ? second : nil)
        plan = PlanUsage.codexPlanName(limits["planType"] as? String)
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
    static func readClaude(ignoringPause: Bool = false) async -> (read: ClaudeRead, plan: String?) {
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
        let (token, problem, plan) = claudeToken(secret)
        guard let token else { return (problem ?? .signedOut, plan) }
        // Kept across launches: restarting Creo shouldn't extend a rate limit.
        let retryKey = "claudeUsageRetryAt"
        if !ignoringPause, Date().timeIntervalSince1970 < UserDefaults.standard.double(forKey: retryKey) { return (.rateLimited, plan) }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                                 timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // ponytail: never renew the token here. Refresh tokens rotate, so using it would sign
        //           Claude Code out; Claude Code renews it next run.
        // ponytail: this endpoint answers 429 with Retry-After 0 and then 200 moments later, so a
        //           read tries three times, ten seconds apart, before giving up for a minute.
        var reply = try? await URLSession.shared.data(for: request)
        for _ in 1...2 where (reply?.1 as? HTTPURLResponse)?.statusCode == 429
            && (reply?.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") == "0" {
            try? await Task.sleep(for: .seconds(10))
            reply = try? await URLSession.shared.data(for: request)
        }
        guard let (data, response) = reply,
              let status = (response as? HTTPURLResponse)?.statusCode else { return (.unreachable, plan) }
        if status == 401 { return (.expired, plan) }
        if status == 429 {
            // ponytail: Retry-After has been 0, 223 and 3550, yet reads worked again within minutes.
            //           Wait a minute on 0 or missing, and never more than ten, so usage isn't hidden.
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            UserDefaults.standard.set(Date().timeIntervalSince1970 + (wait > 0 ? min(wait, 600) : 60), forKey: retryKey)
            return (.rateLimited, plan)
        }
        guard status == 200,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = PlanUsage(claude: body)
        else { return (.unreachable, plan) }
        let kept = body.filter { $0.key == "five_hour" || $0.key == "seven_day" }
        UserDefaults.standard.set(try? JSONSerialization.data(withJSONObject: kept), forKey: claudeSavedKey)
        return (.usage(usage), plan)
    }

    init?(claude body: [String: Any]) {
        self.init(fiveHour: UsageWindow(claude: body["five_hour"] as? [String: Any]),
                  weekly: UsageWindow(claude: body["seven_day"] as? [String: Any]))
    }

    /// The last good reading, so a rate limit at launch still has numbers to show.
    /// A window that has since reset is dropped: its percentage no longer means anything.
    static let claudeSavedKey = "claudeUsageSaved"
    static func savedClaude(_ data: Data?, now: Date = Date()) -> PlanUsage? {
        guard let data, let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let saved = PlanUsage(claude: body) else { return nil }
        return PlanUsage(fiveHour: saved.fiveHour.flatMap { $0.resetsAt > now ? $0 : nil },
                         weekly: saved.weekly.flatMap { $0.resetsAt > now ? $0 : nil })
    }

    /// The usable token in Claude Code's stored credentials, or why there isn't one.
    static func claudeToken(_ secret: Data, now: Date = Date()) -> (token: String?, problem: ClaudeRead?, plan: String?) {
        guard let credentials = (try? JSONSerialization.jsonObject(with: secret)) as? [String: Any],
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return (nil, .signedOut, nil) }
        let plan = planName(oauth["subscriptionType"] as? String, tier: oauth["rateLimitTier"] as? String)
        if let expiry = oauth["expiresAt"] as? Double, expiry / 1000 <= now.timeIntervalSince1970 {
            return (nil, .expired, plan)
        }
        return (token, nil, plan)
    }
}

/// Antigravity's plan and how much of each model is left, from its own local server.
///
/// Antigravity runs a small server on this Mac for its agent panel and writes where to find it,
/// with the access code it expects, to ~/.gemini/antigravity/daemon/hub_<port>.json. Creo asks it
/// the same questions the panel does. Nothing leaves the Mac, and the code is never stored.
// ponytail: an internal API that moved apps in the November 2026 update. Any failure reads as
//           "open Antigravity", which is also the truth whenever it is closed.
struct AntigravityUsage {
    struct Model { let name: String; let window: UsageWindow }
    let plan: String?
    let models: [Model]

    /// Its server, if it is running: base URL and access code.
    static func hub() -> (url: String, code: String)? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity/daemon")
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("hub_") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any],
                  let port = (obj["httpPort"] as? NSNumber)?.intValue,
                  let code = obj["csrfToken"] as? String,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value, kill(pid, 0) == 0   // a file left by a crash
            else { continue }
            return ("http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/", code)
        }
        return nil
    }

    static func call(_ method: String, _ body: [String: Any] = [:]) async -> [String: Any]? {
        guard let hub = hub(), let url = URL(string: hub.url + method) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(hub.code, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Why there is nothing to show: closed, or open but answering in a way Creo can't read.
    /// Why there is no fresh reading. Antigravity's agent service comes and goes on its own, even
    /// with the app open, so "open Antigravity" is only said when the app really is closed.
    static func note(for usage: AntigravityUsage?) -> String? {
        guard usage == nil else { return nil }
        if hub() != nil { return "Couldn't read Antigravity's usage. It may have changed in an update." }
        let open = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier?.localizedCaseInsensitiveContains("antigravity") == true
        }
        return open ? "Antigravity's agent isn't running right now. Use the agent panel in Antigravity to update usage."
            : "Open Antigravity to see model usage here."
    }

    // MARK: The last good reading, kept for when the service is not up.
    // Only the plan and each model's numbers are stored: the full reply carries the user's name
    // and email, which have no business sitting in Creo's settings.
    static let savedKey = "antigravityUsageSaved"

    func save() {
        let models = self.models.map { ["name": $0.name, "remaining": $0.window.remaining,
                                        "reset": $0.window.resetsAt.timeIntervalSince1970] as [String: Any] }
        var saved: [String: Any] = ["models": models]
        if let plan { saved["plan"] = plan }
        UserDefaults.standard.set(try? JSONSerialization.data(withJSONObject: saved), forKey: Self.savedKey)
    }

    /// That reading, minus any model whose quota has reset since, as its number no longer holds.
    static func saved(_ data: Data?, now: Date = Date()) -> AntigravityUsage? {
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let models = (obj["models"] as? [[String: Any]] ?? []).compactMap { m -> Model? in
            guard let name = m["name"] as? String, let left = (m["remaining"] as? NSNumber)?.intValue,
                  let reset = (m["reset"] as? NSNumber)?.doubleValue, reset > now.timeIntervalSince1970 else { return nil }
            return Model(name: name, window: UsageWindow(remaining: left, resetsAt: Date(timeIntervalSince1970: reset)))
        }
        return models.isEmpty ? nil : AntigravityUsage(plan: obj["plan"] as? String, models: models)
    }

    static func read() async -> AntigravityUsage? {
        (await call("GetUserStatus")).flatMap { AntigravityUsage(status: $0) }
    }

    init?(status: [String: Any]) {
        guard let user = status["userStatus"] as? [String: Any] else { return nil }
        let tier = (user["userTier"] as? [String: Any])?["name"] as? String
        let planInfo = ((user["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        // "Google AI Pro" crowds the header next to an update button; the plan is the last word.
        plan = (tier.map { $0.replacingOccurrences(of: "Google AI ", with: "") }) ?? planInfo
        let configs = ((user["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        models = configs.compactMap { config in
            // A model with no reset time has no quota to show. The JSON leaves out zero values, so
            // a used-up model arrives with a reset time and no remainingFraction at all.
            // The display label, else the model's own id, so a renamed field still shows something.
            let name = [config["label"], config["modelId"], (config["modelOrAlias"] as? [String: Any])?["model"]]
                .compactMap { $0 as? String }.first { !$0.isEmpty }
            guard let name,
                  let quota = config["quotaInfo"] as? [String: Any],
                  let reset = (quota["resetTime"] as? String).flatMap(iso.date(from:)) else { return nil }
            let left = (quota["remainingFraction"] as? NSNumber)?.doubleValue ?? 0
            return Model(name: name, window: UsageWindow(remaining: max(0, min(100, Int((left * 100).rounded()))),
                                                         resetsAt: reset))
        }
    }

    init(plan: String?, models: [Model]) {
        self.plan = plan
        self.models = models
    }

    /// Models that share a quota read as one: "Gemini 3.8 Flash (High)", "(Medium)" and "(Low)"
    /// with the same amount left and the same reset are "Gemini 3.8 Flash". A model that is the
    /// only one of its name drops the suffix too ("Claude Opus 4.6"); variants that differ keep it.
    var grouped: [Model] {
        func base(_ name: String) -> String {
            name.replacingOccurrences(of: #"\s*\([^)]*\)$"#, with: "", options: .regularExpression)
        }
        var out: [Model] = []
        for model in models {
            if let last = out.last, base(last.name) == base(model.name),
               last.window.remaining == model.window.remaining, last.window.resetsAt == model.window.resetsAt {
                out[out.count - 1] = Model(name: base(model.name), window: model.window)
            } else {
                out.append(model)
            }
        }
        return out.map { model in
            out.filter { base($0.name) == base(model.name) }.count == 1
                ? Model(name: base(model.name), window: model.window) : model
        }
    }

    /// The model closest to its limit, which is what the rail's ring shows.
    var lowest: UsageWindow? { models.map(\.window).min { $0.remaining < $1.remaining } }

    /// Tokens a conversation has used, input and output, added up across every model call.
    static func tokens(_ id: String) async -> (input: Int, output: Int, byModel: [String: Int])? {
        guard let reply = await call("GetCascadeTrajectoryGeneratorMetadata", ["cascadeId": id]) else { return nil }
        return tokens(in: reply)
    }

    /// Tokens in and out, plus the total per model by the name Antigravity shows for it.
    static func tokens(in reply: [String: Any]) -> (input: Int, output: Int, byModel: [String: Int])? {
        // Counts arrive as strings ("62593"), the protobuf JSON form for 64-bit numbers.
        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) ?? 0 }
        var input = 0, output = 0, calls = 0
        var byModel: [String: Int] = [:]
        for generation in reply["generatorMetadata"] as? [[String: Any]] ?? [] {
            let chat = generation["chatModel"] as? [String: Any]
            let model = chat?["modelDisplayName"] as? String
            for attempt in chat?["retryInfos"] as? [[String: Any]] ?? [] {
                guard let usage = attempt["usage"] as? [String: Any] else { continue }
                let (i, o) = (number(usage["inputTokens"]), number(usage["outputTokens"]))
                input += i
                output += o
                calls += 1
                if let model { byModel[model, default: 0] += i + o }
            }
        }
        return calls == 0 ? nil : (input, output, byModel)
    }

    /// Most used first: the model with the least left, then the one with the most tokens across
    /// your conversations, then Antigravity's own order. Nothing here names a model.
    func ordered(byTokens tokens: [String: Int]) -> [Model] {
        // A grouped "Gemini 3.8 Flash" collects the tokens of every "Gemini 3.8 Flash (…)".
        func used(_ name: String) -> Int {
            tokens.reduce(0) { $0 + ($1.key == name || $1.key.hasPrefix(name + " (") ? $1.value : 0) }
        }
        return grouped.enumerated().sorted { a, b in
            if a.element.window.remaining != b.element.window.remaining {
                return a.element.window.remaining < b.element.window.remaining
            }
            let (ua, ub) = (used(a.element.name), used(b.element.name))
            return ua != ub ? ua > ub : a.offset < b.offset
        }.map(\.element)
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var usage: [Service: PlanUsage] = [:]
    @Published var claudeNote: String? = "Reading usage…"
    /// From the stored sign-in, so it stays known while the usage request is failing.
    @Published var claudePlan: String?
    @Published var antigravity: AntigravityUsage?
    @Published var antigravityNote: String? = "Open Antigravity to see model usage here."
    /// "62.6k in · 2.0k out" per Antigravity conversation, read while its server is up.
    @Published var antigravityTokens: [String: String] = [:]
    /// Tokens per model across the conversations read so far, to put the most used first.
    @Published var antigravityModelTokens: [String: Int] = [:]
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
    case chatgpt, claude, antigravity

    /// Services whose plan usage Creo can read locally.
    static let tracked: [Service] = [.chatgpt, .claude]

    var title: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .antigravity: "Antigravity"
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
        case .antigravity: .antigravity
        }
    }
}

/// 62593 reads "62.6k", 1200000 reads "1.2M".
func tokenCount(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : "\(n)"
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

extension View {
    /// A horizontal scroll view that opens at its first item.
    // ponytail: macOS 14's defaultScrollAnchor; on 13 it opens wherever AppKit puts it.
    @ViewBuilder func startingAtLeadingEdge() -> some View {
        if #available(macOS 14.0, *) { defaultScrollAnchor(.leading) } else { self }
    }
}

/// One Antigravity model: a ring of what is left, the number inside, its name below.
/// Hover for the reset time.
private struct ModelRing: View {
    let model: AntigravityUsage.Model
    /// Whether any model in the row has a variant line, so every cell keeps the same height.
    let showsVariant: Bool

    static let ring: CGFloat = 26
    /// Four across the 316-point row, with the gaps between them.
    static let width: CGFloat = 76
    /// Ring, name, and the variant line when there is one.
    static func height(showsVariant: Bool) -> CGFloat { 2 + ring + 2 + 12 + (showsVariant ? 10 : 0) }

    /// "Gemini 3.8 Flash (High)" splits into "Gemini 3.8 Flash" and "High".
    static func parts(_ name: String) -> (base: String, variant: String?) {
        guard let open = name.range(of: " (", options: .backwards), name.hasSuffix(")") else { return (name, nil) }
        return (String(name[..<open.lowerBound]), String(name[open.upperBound...].dropLast()))
    }

    var body: some View {
        let parts = Self.parts(model.name)
        VStack(spacing: 0) {
            // Inset by half the line so the stroke stays inside the ring's box; a stroke on the edge
            // pokes out, and the scroll area clipped the top of every ring flat.
            ZStack {
                Circle().inset(by: 1.5).stroke(Color.primary.opacity(0.13), lineWidth: 3)
                Circle().inset(by: 1.5).trim(from: 0, to: CGFloat(model.window.remaining) / 100)
                    .stroke(model.window.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.32), value: model.window.remaining)
                Text("\(model.window.remaining)").font(.system(size: 9, weight: .semibold))
            }
            .frame(width: Self.ring, height: Self.ring)
            .padding(.top, 2)
            .padding(.bottom, 2)
            Text(parts.base)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(Color.primary.opacity(0.7))
                .frame(height: 12)
            if showsVariant {
                Text(parts.variant ?? " ")
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .frame(height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .help("\(model.name): \(model.window.remaining)% left, resets "
              + model.window.resetsAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.name), \(model.window.remaining) percent remaining")
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
        sessions.filter { session in
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
        if service == .antigravity {
            guard let lowest = state.antigravity?.lowest else { return "Open Antigravity to see usage" }
            return "\(lowest.remaining)% left on the model closest to its limit"
        }
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
            // Only Antigravity's server knows what each conversation used, so ask it per row.
            var perModel: [String: Int] = [:]
            for session in sessions.filter({ $0.agent == .antigravity }).prefix(20) {
                guard let used = await AntigravityUsage.tokens(session.sessionID) else { continue }
                state.antigravityTokens[session.sessionID] = "\(tokenCount(used.input)) in · \(tokenCount(used.output)) out"
                perModel.merge(used.byModel, uniquingKeysWith: +)
            }
            if !perModel.isEmpty { state.antigravityModelTokens = perModel }
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
                if let plan = selected == .claude ? state.claudePlan
                    : selected == .antigravity ? state.antigravity?.plan : state.usage[selected]?.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                }
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
                    .layoutPriority(1)   // the plan badge gives way first when the header is tight
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

            HStack(spacing: 6) {
                Text(searching ? "Searching…" : "\(visibleSessions.count) sessions")
                    .frame(minWidth: 52, alignment: .leading)
                filterButton("All", agent: nil)
                filterButton("ChatGPT", agent: .codex)
                filterButton("Claude", agent: .claude)
                filterButton("Antigravity", agent: .antigravity)
                Spacer(minLength: 0)
                Button { activeOnly.toggle() } label: {
                    Label("Active", systemImage: activeOnly ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(activeOnly ? Color.green : Color.primary.opacity(0.6))
                }
                .buttonStyle(.plain)
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
                } else if service == .antigravity, let lowest = state.antigravity?.lowest {
                    Circle().trim(from: 0, to: CGFloat(lowest.remaining) / 100)
                        .stroke(lowest.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
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

    /// Why the numbers on screen may be old: Claude's last read failed but an earlier one worked.
    private func staleNote(_ service: Service) -> String? {
        if service == .antigravity { return state.antigravity != nil ? state.antigravityNote : nil }
        return service == .claude && state.usage[.claude] != nil ? state.claudeNote : nil
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
        VStack(alignment: .leading, spacing: selected == .antigravity ? 5 : 9) {
            HStack {
                // Numbers kept from an earlier read stay on screen, so say so without adding a row.
                Text(staleNote(selected) == nil ? "Usage remaining" : "Usage may be out of date")
                    .help(staleNote(selected) ?? "")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                // Antigravity's models reset together, so say when once instead of on every bar.
                if selected == .antigravity, let reset = state.antigravity?.models.map(\.window.resetsAt).min() {
                    Text("Resets \(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
                if Service.tracked.contains(selected) || selected == .antigravity {
                    Button {
                        NotchController.shared.refreshUsage(ignoringPause: true)   // an explicit ask
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Refresh usage")
                }
            }
            .padding(.bottom, selected == .antigravity ? 7 : 0)   // room between the title and the rings
            if Service.tracked.contains(selected) {
                if let window = state.usage[selected]?.fiveHour { UsageBar(title: "5h", window: window) }
                if let window = state.usage[selected]?.weekly { UsageBar(title: "Weekly", window: window) }
                if selected == .claude, staleNote(selected) == nil, let note = state.claudeNote {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.6))
                } else if selected == .chatgpt, state.usage[selected] == nil {
                    Text("Sign in to Codex to see usage here.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
            } else if let models = state.antigravity?.ordered(byTokens: state.antigravityModelTokens), !models.isEmpty {
                // One row, most used first, scrolling sideways past four. Four or fewer share the row;
                // with more, each is a little narrower so the fifth peeks in, showing there is more.
                // The area gets an exact height: left to work it out, it came out too short.
                let variants = models.contains { ModelRing.parts($0.name).variant != nil }
                // Start at the front, where the most used are. Not ScrollViewReader.scrollTo: calling
                // it as the panel switched to Antigravity left the whole flyout blank (39 of 40 tries).
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(models, id: \.name) {
                            ModelRing(model: $0, showsVariant: variants)
                                .frame(width: models.count > 4 ? ModelRing.width - 8 : ModelRing.width)
                        }
                    }
                }
                .startingAtLeadingEdge()
                .frame(height: ModelRing.height(showsVariant: variants))
                .scrollIndicators(models.count > 4 ? .visible : .hidden)
            } else {
                Text(state.antigravityNote ?? "Open Antigravity to see model usage here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.6))
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
                HStack(spacing: 6) {
                    Text(session.shortPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let tokens = state.antigravityTokens[session.sessionID] {
                        Text(tokens).help("Tokens this conversation has used")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.53))
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
            // Antigravity keeps its own record of a conversation; trashing one file leaves it listed.
            if session.agent != .antigravity {
                Button("Move to Trash…", role: .destructive) {
                    if confirmAndTrash(session) { state.refreshToken += 1 }
                }
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
    private var lastUsageRefresh = Date.distantPast
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
        state.usage[.claude] = PlanUsage.savedClaude(UserDefaults.standard.data(forKey: PlanUsage.claudeSavedKey))
        refreshUsage()
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
        // ponytail: read on open, not on a timer, because Claude's endpoint rate limits. The floor
        //           only stops quick re-clicks from spending requests; ↻ always reads.
        // Missing or old numbers are worth another try straight away; otherwise once per 30 seconds.
        if Date().timeIntervalSince(lastUsageRefresh) > 30 || state.antigravityNote != nil { refreshUsage() }
        // Ask again on every open (cached for a minute), so a release published while the app
        // was running shows up now instead of at the next two-hour check.
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
                // A second click inside the first one's opening cancels it before the flyout has
                // grown, which left a wide panel with its outline still folded. Grow it here too.
                if self.state.expansion < 1 {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) { self.state.expansion = 1 }
                }
                withAnimation(.easeOut(duration: 0.18)) { self.state.detailVisible = true }
            }
        }
    }

    func refreshUsage(ignoringPause: Bool = false) {
        lastUsageRefresh = Date()
        // Each service shows as soon as its own answer is in. Waiting for all three let a
        // rate-limited Claude, retrying for twenty seconds, hold back the other two.
        Task.detached(priority: .utility) {
            let fresh = await AntigravityUsage.read()
            fresh?.save()
            let note = AntigravityUsage.note(for: fresh)
            // No fresh reading: show the last one under "may be out of date", or the note alone.
            let shown = fresh ?? AntigravityUsage.saved(UserDefaults.standard.data(forKey: AntigravityUsage.savedKey))
            await MainActor.run {
                self.state.antigravity = shown
                self.state.antigravityNote = note
            }
        }
        Task.detached(priority: .utility) {
            let codex = PlanUsage.readCodex()
            await MainActor.run {
                // A failed read keeps the last good value instead of blanking the ring.
                if let codex { self.state.usage[.chatgpt] = codex }
                self.updateStatusIcon()
            }
        }
        Task.detached(priority: .utility) {
            let (claudeRead, claudePlan) = await PlanUsage.readClaude(ignoringPause: ignoringPause)
            await MainActor.run {
                switch claudeRead {
                case .usage(let usage): self.state.usage[.claude] = usage
                case .signedOut:   // those numbers aren't yours now
                    self.state.usage[.claude] = nil
                    UserDefaults.standard.removeObject(forKey: PlanUsage.claudeSavedKey)
                case .expired, .rateLimited, .unreachable: break
                }
                self.state.claudeNote = claudeRead.note
                self.state.claudePlan = claudePlan
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
