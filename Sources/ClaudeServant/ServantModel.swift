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
    @Published var logTail: [String] = []
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
        Notifier.shared.setup()
        refresh()
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

    var activeSessions: [SessionInfo] {
        sessions.filter { Date().timeIntervalSince($0.lastActivity) < 5 * 60 }
    }

    func refresh() {
        config = ConfigStore.loadOrCreate()   // pick up manual edits to config.json
        usage = UsageReader.read()
        sessions = SessionTracker.recent()
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
            if !isRunning { pendingAsk = true }
            return
        }

        let idleFor = sessions.first.map { now.timeIntervalSince($0.lastActivity) } ?? .infinity
        let cooledDown = state.lastAskedAt.map { now.timeIntervalSince($0) > config.askCooldownHours * 3600 } ?? true
        if config.autoAskWhenIdle, !isRunning, !pendingAsk, cooledDown,
           idleFor > config.idleMinutesBeforeAsking * 60,
           config.projects.contains(where: { $0.enabled }) {
            ask()
        }
    }

    func ask() {
        pendingAsk = true
        state.lastAskedAt = Date()
        save()
        Notifier.shared.post(title: "Claude session is free", body: Notifier.askQuestion, ask: true)
        if !Notifier.shared.authorized { showAskAlert() }
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
        Task {
            var lines: [String] = []
            for p in projects {
                currentProject = p.name
                appendLog("▶︎ \(p.name)")
                let r = ProjectRunner(config: config, project: p) { line in
                    Task { @MainActor in ServantModel.shared.appendLog(line) }
                }
                runner = r
                let out = await r.run()
                lines.append("\(p.name): \(out.headline)")
                if out.hitLimit {
                    state.limitHitUntil = usage?.fiveHourResetsAt.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(3600)
                }
                if r.cancelled || out.hitLimit { break }
            }
            runner = nil
            currentProject = nil
            isRunning = false
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
        logTail.append(s)
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
