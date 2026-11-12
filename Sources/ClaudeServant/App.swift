import AppKit
import SwiftUI

@main
struct ClaudeServantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = ServantModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Window("Project Settings", id: "project-editor") {
            ProjectEditor().environmentObject(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in ServantModel.shared.start() }
    }
}

struct MenuLabel: View {
    @EnvironmentObject var model: ServantModel
    var body: some View {
        if model.isRunning {
            Image(systemName: "gearshape.2.fill")
        } else if model.limitedUntil != nil {
            Image(systemName: "hourglass")
        } else if model.pendingAsk {
            Image(systemName: "sparkles")
        } else {
            Image(systemName: "sparkle")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var model: ServantModel
    @Environment(\.openWindow) private var openWindow

    private func edit(_ id: String) {
        model.editingProjectID = id
        openWindow(id: "project-editor")
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            setupWarnings
            if model.pendingAsk && !model.isRunning { askCard }
            usageSection
            Divider()
            sessionsSection
            Divider()
            projectsSection
            if model.isRunning || !model.logTail.isEmpty { logSection }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Claude Servant").font(.headline)
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder private var statusBadge: some View {
        if model.isRunning {
            Label("Working on \(model.currentProject ?? "…")", systemImage: "gearshape.2").font(.caption).foregroundStyle(.blue)
        } else if let until = model.limitedUntil {
            Label("Limited until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
        } else {
            Label("Session available", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        }
    }

    private var askCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Notifier.askQuestion).font(.callout)
            HStack {
                Button("Yes, work on projects") { model.answer(true) }.buttonStyle(.borderedProminent)
                Button("No") { model.answer(false) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
    }

    @ViewBuilder private var usageSection: some View {
        if let u = model.usage {
            VStack(alignment: .leading, spacing: 6) {
                usageRow("5-hour window", pct: u.fiveHourPct, resets: u.fiveHourResetsAt)
                usageRow("Weekly", pct: u.sevenDayPct, resets: u.sevenDayResetsAt)
                Text("Usage data from \(u.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            Text("No usage data yet. Open Claude Code once so the status line hook can record your limits.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usageRow(_ title: String, pct: Double?, resets: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "–").font(.caption.monospacedDigit())
                if let r = resets, r > Date() {
                    Text("· resets \(r.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(max((pct ?? 0) / 100, 0), 1))
                .tint((pct ?? 0) >= model.config.limitThresholdPercent ? .orange : .accentColor)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Sessions (24h)").font(.subheadline.bold())
                Spacer()
                Text("\(model.sessions.count) total · \(model.activeSessions.count) active").font(.caption).foregroundStyle(.secondary)
            }
            if model.sessions.isEmpty {
                Text("No Claude Code sessions in the last 24 hours.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.sessions.prefix(5)) { s in
                HStack {
                    Circle().fill(Date().timeIntervalSince(s.lastActivity) < 300 ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(s.project).font(.caption).lineLimit(1)
                    Spacer()
                    Text(s.lastActivity.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var setupWarnings: some View {
        if Paths.resolveClaude(model.config.claudePath) == nil {
            warning("Claude Code CLI not found. Install it, or set \"claudePath\" in config.json.")
        }
        if !FileManager.default.isExecutableFile(atPath: Paths.screenshotTool.path) {
            warning("Helpers not installed. Run scripts/install.sh from the repo.")
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Projects").font(.subheadline.bold())
                Button {
                    if let id = model.addProjectsViaPanel() { edit(id) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Add project folders for Claude to work on")
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stopRun() }
                } else {
                    Button("Work on projects now") { model.startRun() }
                        .disabled(!model.config.projects.contains { $0.enabled })
                }
            }
            if model.config.projects.isEmpty {
                Button {
                    if let id = model.addProjectsViaPanel() { edit(id) }
                } label: {
                    Label("Add a project folder Claude can improve on its own", systemImage: "folder.badge.plus")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                }
                .buttonStyle(.plain)
            }
            ForEach(model.config.projects) { p in
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { p.enabled }, set: { _ in model.toggleProject(p) })) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(p.name).font(.caption)
                            Text(p.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .toggleStyle(.checkbox)
                    if model.currentProject == p.name {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("Run") { model.startRun(only: p) }.font(.caption).disabled(model.isRunning)
                    Button { edit(p.id) } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless).help("Project settings")
                }
            }
            if let s = model.state.lastRunSummary, let at = model.state.lastRunAt, !model.isRunning {
                Text("Last run \(at.formatted(.relative(presentation: .named))): \(s)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(4)
            }
        }
    }

    private var logSection: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.logTail.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 10, design: .monospaced)).lineLimit(3).id(i)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 140)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            .onChange(of: model.logTail.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.caption)
            Spacer()
            Menu("More") {
                Button("Ask me now") { model.ask() }
                Button("Refresh") { model.refresh() }
                Button("Edit config…") { model.openConfig() }
                Button("Open logs folder") { model.openLogs() }
                Divider()
                Button("Quit Claude Servant") { NSApp.terminate(nil) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
