import AppKit
import Foundation
import ServiceManagement

@MainActor
final class ServantModel: ObservableObject {
    static let shared = ServantModel()

    @Published var config: ServantConfig
    @Published var usage: UsageSnapshot?
    @Published var sessions: [SessionInfo] = []
    @Published var isRunning = false
    @Published var currentProject: String?
    struct LogLine: Identifiable { let id: Int; let text: String }
    @Published var logTail: [LogLine] = []
    private var logCounter = 0
    /// Time ranges during which Servant's own `claude -p` sessions were active (excluded from "user activity").
    private var ownRuns: [(start: Date, end: Date)] = []
    private var runStart: Date?
    private var refreshing = false
    @Published var pendingAsk = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var state: ServantState

    private var timer: Timer?
    private var runner: ProjectRunner?
    private static let resetNoticeID = "session-reset"

    init() {
        config = ConfigStore.loadOrCreate()
        state = StateStore.load()
    }

    func start() {
        Notifier.shared.onAnswer = { [weak self] yes in self?.answer(yes) }
        Notifier.shared.onOpenAsk = { [weak self] in self?.showAskAlert() }
        Notifier.shared.setup { [weak self] in self?.refresh() }   // first refresh once authorization is known
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in ServantModel.shared.refresh() }
        }
    }

    // MARK: - Session / limit tracking

    var limitedUntil: Date? {
        let now = Date()
        var until: Date?
        let th = config.limitThresholdPercent
        if let u = usage {
            if let p = u.fiveHourPct, p >= th, let r = u.fiveHourResetsAt, r > now { until = r }
            if let p = u.sevenDayPct, p >= th, let r = u.sevenDayResetsAt, r > now { until = max(until ?? r, r) }
        }
        if let h = state.limitHitUntil, h > now { until = max(until ?? h, h) }
        return until
    }

    /// Sessions started by you, i.e. not by Servant's own unattended runs.
    var userSessions: [SessionInfo] {
        sessions.filter { s in
            !ownRuns.contains { s.lastActivity >= $0.start && s.lastActivity <= $0.end.addingTimeInterval(120) }
                && !(runStart.map { s.lastActivity >= $0 } ?? false)
        }
    }

    var activeSessions: [SessionInfo] {
        userSessions.filter { Date().timeIntervalSince($0.lastActivity) < 5 * 60 }
    }

    /// File reads happen off the main thread; results are applied on it.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task.detached(priority: .utility) {
            let cfg = ConfigStore.loadOrCreate()   // picks up manual edits to config.json
            let usage = UsageReader.read()
            let sessions = SessionTracker.recent()
            await MainActor.run {
                let m = ServantModel.shared
                m.config = cfg; m.usage = usage; m.sessions = sessions
                m.refreshing = false
                m.evaluate()
            }
        }
    }

    private func evaluate() {
        let now = Date()

        if let until = limitedUntil {
            if state.waitingForReset != until {
                state.waitingForReset = until
                save()
                // Delivered by macOS at reset time; carries Yes/No buttons.
                Notifier.shared.post(id: Self.resetNoticeID, title: "Claude session available 🎉",
                                     body: "Your usage limit has reset. " + Notifier.askQuestion, ask: true, at: until)
            }
            return
        }

        if let w = state.waitingForReset, now >= w {
            state.waitingForReset = nil
            state.limitHitUntil = nil
            state.lastAskedAt = now
            save()
            if !isRunning, config.projects.contains(where: { $0.enabled }) { pendingAsk = true }
            return
        }

        // Limit cleared early (threshold changed, fresh usage data): drop the reset notification still scheduled.
        if state.waitingForReset != nil, state.waitingForReset! > now {
            Notifier.shared.cancel(id: Self.resetNoticeID)
            state.waitingForReset = nil
            save()
        }

        let idleFor = userSessions.first.map { now.timeIntervalSince($0.lastActivity) } ?? .infinity
        let cooledDown = state.lastAskedAt.map { now.timeIntervalSince($0) > config.askCooldownHours * 3600 } ?? true
        if config.autoAskWhenIdle, !isRunning, !pendingAsk, cooledDown,
           idleFor > config.idleMinutesBeforeAsking * 60,
           config.projects.contains(where: { $0.enabled }) {
            ask(interactive: false)
        }
    }

    /// `interactive` = the user explicitly asked ("Ask me now"); only then may a modal dialog appear.
    func ask(interactive: Bool = true) {
        pendingAsk = true
        state.lastAskedAt = Date()
        save()
        Notifier.shared.post(title: "Claude session is free", body: Notifier.askQuestion, ask: true)
        if interactive && !Notifier.shared.authorized { showAskAlert() }
    }

    func showAskAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Claude session available"
        let names = config.projects.filter { $0.enabled }.map(\.name).joined(separator: ", ")
        a.informativeText = Notifier.askQuestion + "\n\nProjects: " + (names.isEmpty ? "none enabled" : names)
        a.addButton(withTitle: "Yes")
        a.addButton(withTitle: "No")
        answer(a.runModal() == .alertFirstButtonReturn)
    }

    func answer(_ yes: Bool) {
        pendingAsk = false
        if yes { startRun() }
    }

    // MARK: - Running projects

    func startRun(only: ProjectConfig? = nil) {
        guard !isRunning else { return }
        let projects = only.map { [$0] } ?? config.projects.filter { $0.enabled }
        guard !projects.isEmpty else { return }
        isRunning = true
        logTail = []
        runStart = Date()
        Task {
            var lines: [String] = []
            for p in projects {
                currentProject = p.name
                appendLog("▶︎ \(p.name)")
                let r = ProjectRunner(config: config, project: p) { line in
                    DispatchQueue.main.async { ServantModel.shared.appendLog(line) }
                }
                runner = r
                let out = await r.run()
                lines.append("\(p.name): \(out.headline)")
                if out.hitLimit {
                    let th = config.limitThresholdPercent
                    let weekly = (usage?.sevenDayPct ?? 0) >= th ? usage?.sevenDayResetsAt : nil
                    let fiveH = usage?.fiveHourResetsAt
                    state.limitHitUntil = [weekly, fiveH].compactMap { $0 }.filter { $0 > Date() }.max()
                        ?? Date().addingTimeInterval(3600)
                }
                if r.cancelled || out.hitLimit { break }
            }
            runner = nil
            currentProject = nil
            isRunning = false
            if let s = runStart { ownRuns.append((s, Date())); ownRuns = Array(ownRuns.suffix(50)) }
            runStart = nil
            let summary = lines.joined(separator: "\n")
            state.lastRunAt = Date()
            state.lastRunSummary = summary
            save()
            Notifier.shared.post(title: "Claude Servant finished", body: summary)
            refresh()
        }
    }

    func stopRun() { runner?.cancel() }

    func appendLog(_ s: String) {
        logCounter += 1
        logTail.append(LogLine(id: logCounter, text: s))
        if logTail.count > 200 { logTail.removeFirst(logTail.count - 200) }
    }

    // MARK: - Settings

    func toggleProject(_ p: ProjectConfig) {
        guard let i = config.projects.firstIndex(where: { $0.id == p.id }) else { return }
        config.projects[i].enabled.toggle()
        ConfigStore.save(config)
    }

    @Published var editingProjectID: String?

    /// Shows a folder picker; returns the id of the new project (to open in the editor).
    func addProjectsViaPanel() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose project folders for Claude to work on"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = Paths.home.appendingPathComponent("Projects")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        var lastID: String?
        for url in panel.urls {
            if config.projects.contains(where: { $0.expandedPath == url.path }) { continue }
            let p = ProjectConfig.detect(folder: url, existing: config.projects)
            config.projects.append(p)
            lastID = p.id
        }
        ConfigStore.save(config)
        return panel.urls.count == 1 ? lastID : nil
    }

    func updateProject(_ p: ProjectConfig) {
        guard let i = config.projects.firstIndex(where: { $0.id == p.id }) else { return }
        config.projects[i] = p
        ConfigStore.save(config)
    }

    func removeProject(id: String) {
        config.projects.removeAll { $0.id == id }
        ConfigStore.save(config)
    }

    func isGitRepo(_ p: ProjectConfig) -> Bool {
        FileManager.default.fileExists(atPath: p.expandedPath + "/.git")
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func openConfig() { NSWorkspace.shared.open(Paths.config) }
    func openLogs() { NSWorkspace.shared.open(Paths.logs) }

    private func save() { StateStore.save(state) }
}
