import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let servantDir = home.appendingPathComponent(".claude/servant")
    static let config = servantDir.appendingPathComponent("config.json")
    static let state = servantDir.appendingPathComponent("state.json")
    static let usage = servantDir.appendingPathComponent("usage.json")
    static let logs = servantDir.appendingPathComponent("logs")
    static let screenshotTool = servantDir.appendingPathComponent("bin/screenshot.sh")
    static let claudeProjects = home.appendingPathComponent(".claude/projects")
    static let screenshots = servantDir.appendingPathComponent("screenshots")

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Shortens /Users/me/x to ~/x for display and storage.
    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func ensureDirs() {
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    /// Finds the `claude` CLI: configured path first, then common install locations.
    static func resolveClaude(_ configured: String) -> String? {
        let candidates = [configured, "~/.local/bin/claude", "~/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.npm-global/bin/claude"]
        return candidates.map(expand).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct ProjectConfig: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var path: String
    var enabled: Bool = true
    /// Command that starts a dev server; "{{PORT}}" is substituted and $PORT is set. nil = no server / no screenshots.
    var devCommand: [String]?
    var devPort: Int?
    /// Refuse to run if the repo has uncommitted changes (protects your work-in-progress).
    var requireCleanTree: Bool = true
    /// Push to the tracked remote after committing.
    var autoPush: Bool = true
    /// What Claude should focus on. Servant wraps it with standard unattended-run rules.
    var prompt: String = ProjectConfig.defaultTask
    /// Extra Bash permission rules for this project, e.g. "Bash(pytest:*)".
    var extraAllowedTools: [String]?

    static let defaultTask = """
    Make this project better. Choose 1–3 focused, high-impact improvements: fix bugs, polish the UI/UX, \
    improve performance or robustness, or clean up confusing code. Prefer changes a user would notice. \
    Do not add dependencies and do not hand-edit large generated or data files.
    """

    var expandedPath: String { Paths.expand(path) }
    var hasDevServer: Bool { !(devCommand ?? []).isEmpty }

    /// Builds a project entry for a folder, detecting a JS dev server if there is one.
    static func detect(folder: URL, existing: [ProjectConfig]) -> ProjectConfig {
        var name = folder.lastPathComponent
        let names = Set(existing.map(\.name))
        var n = 2
        while names.contains(name) { name = "\(folder.lastPathComponent) \(n)"; n += 1 }

        var p = ProjectConfig(name: name, path: Paths.abbreviate(folder.path))
        let pkg = folder.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: pkg),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: String] {
            let script = scripts["dev"] != nil ? "dev" : (scripts["start"] != nil ? "start" : nil)
            if let script {
                let body = scripts[script] ?? ""
                var cmd = ["npm", "run", script]
                if body.contains("next") { cmd += ["--", "-p", "{{PORT}}"] }
                else if body.contains("vite") { cmd += ["--", "--port", "{{PORT}}", "--strictPort"] }
                else if body.contains("astro") { cmd += ["--", "--port", "{{PORT}}"] }
                p.devCommand = cmd
                let used = Set(existing.compactMap(\.devPort))
                var port = 3123
                while used.contains(port) { port += 1 }
                p.devPort = port
            }
        }
        return p
    }
}

struct ServantConfig: Codable {
    var claudePath: String = "~/.local/bin/claude"
    /// Treat the window as "used up" at or above this percentage.
    var limitThresholdPercent: Double = 95
    /// Ask "should I work on projects?" when no Claude session has been active for this long.
    var autoAskWhenIdle: Bool = true
    var idleMinutesBeforeAsking: Double = 45
    /// Don't ask more often than this.
    var askCooldownHours: Double = 5
    var maxTurns: Int = 120
    var baseAllowedTools: [String] = ServantConfig.defaultAllowedTools
    var projects: [ProjectConfig] = []

    static let defaultAllowedTools = [
        "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
        "Bash(git add:*)", "Bash(git commit:*)", "Bash(git push)",
        "Bash(git restore:*)", "Bash(git checkout -- :*)",
        "Bash(npm run lint:*)", "Bash(npm run build:*)", "Bash(npm run test:*)", "Bash(npm test:*)",
        "Bash(npx --no-install eslint:*)", "Bash(npx --no-install tsc:*)",
        "Bash(ls:*)", "Bash(mkdir -p:*)", "Bash(wc:*)",
        "Bash(~/.claude/servant/bin/screenshot.sh:*)",
        "TodoWrite"
    ]
}

enum ConfigStore {
    private static let lock = NSLock()
    private static var lastGood: ServantConfig?
    private static var lastMTime: Date?
    /// True while config.json exists but cannot be parsed; saving is disabled so the user's file is never clobbered.
    private(set) static var parseFailed = false

    private static func mtime() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Paths.config.path)[.modificationDate]) as? Date
    }

    static func loadOrCreate() -> ServantConfig {
        lock.lock(); defer { lock.unlock() }
        Paths.ensureDirs()
        let m = mtime()
        if let good = lastGood, let m, m == lastMTime { return good }
        if let data = try? Data(contentsOf: Paths.config) {
            if let cfg = try? JSONDecoder().decode(ServantConfig.self, from: data) {
                lastGood = cfg; lastMTime = m; parseFailed = false
                return cfg
            }
            if !parseFailed { NSLog("Claude Servant: config.json could not be parsed; keeping last good config and disabling saves") }
            parseFailed = true
            return lastGood ?? ServantConfig()
        }
        let cfg = ServantConfig()
        writeLocked(cfg)
        return cfg
    }

    static func save(_ cfg: ServantConfig) {
        lock.lock(); defer { lock.unlock() }
        guard !parseFailed else { NSLog("Claude Servant: not saving, config.json has a syntax error"); return }
        writeLocked(cfg)
    }

    private static func writeLocked(_ cfg: ServantConfig) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(cfg), (try? data.write(to: Paths.config, options: .atomic)) != nil {
            lastGood = cfg; lastMTime = mtime()
        }
    }
}

struct ServantState: Codable {
    var waitingForReset: Date?
    var limitHitUntil: Date?
    var lastAskedAt: Date?
    var lastRunAt: Date?
    var lastRunSummary: String?
}

enum StateStore {
    static func load() -> ServantState {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Paths.state), let s = try? dec.decode(ServantState.self, from: d) { return s }
        return ServantState()
    }
    static func save(_ s: ServantState) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        if let d = try? enc.encode(s) { try? d.write(to: Paths.state, options: .atomic) }
    }
}

// Tolerant decoding: any key missing from a hand-edited config.json falls back to its default.
extension ServantConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ServantConfig()
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        limitThresholdPercent = try c.decodeIfPresent(Double.self, forKey: .limitThresholdPercent) ?? d.limitThresholdPercent
        autoAskWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .autoAskWhenIdle) ?? d.autoAskWhenIdle
        idleMinutesBeforeAsking = try c.decodeIfPresent(Double.self, forKey: .idleMinutesBeforeAsking) ?? d.idleMinutesBeforeAsking
        askCooldownHours = try c.decodeIfPresent(Double.self, forKey: .askCooldownHours) ?? d.askCooldownHours
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? d.maxTurns
        baseAllowedTools = try c.decodeIfPresent([String].self, forKey: .baseAllowedTools) ?? d.baseAllowedTools
        var ps = try c.decodeIfPresent([ProjectConfig].self, forKey: .projects) ?? d.projects
        var seen = Set<String>()
        for i in ps.indices {
            var id = ps[i].id, n = 2
            while seen.contains(id) { id = "\(ps[i].id)-\(n)"; n += 1 }
            ps[i].id = id; seen.insert(id)
        }
        projects = ps
    }
}

extension ProjectConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? name
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        devCommand = try c.decodeIfPresent([String].self, forKey: .devCommand)
        devPort = try c.decodeIfPresent(Int.self, forKey: .devPort)
        requireCleanTree = try c.decodeIfPresent(Bool.self, forKey: .requireCleanTree) ?? true
        autoPush = try c.decodeIfPresent(Bool.self, forKey: .autoPush) ?? true
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ProjectConfig.defaultTask
        extraAllowedTools = try c.decodeIfPresent([String].self, forKey: .extraAllowedTools)
    }
}
