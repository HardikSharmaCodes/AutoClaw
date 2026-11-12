import AppKit
import SwiftUI

/// Window for editing one project's settings.
struct ProjectEditor: View {
    @EnvironmentObject var model: ServantModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var draft: ProjectConfig?
    @State private var devCommandText = ""
    @State private var portText = ""
    @State private var extraToolsText = ""
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                form(binding)
            } else {
                VStack(spacing: 8) {
                    Text("No project selected").font(.headline)
                    Text("Use + in the Claude Servant menu to add one.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: load)
        .onChange(of: model.editingProjectID) { _, _ in load() }
    }

    private func load() {
        guard let id = model.editingProjectID, let p = model.config.projects.first(where: { $0.id == id }) else {
            draft = nil; return
        }
        draft = p
        devCommandText = (p.devCommand ?? []).joined(separator: " ")
        portText = p.devPort.map(String.init) ?? ""
        extraToolsText = (p.extraAllowedTools ?? []).joined(separator: "\n")
        confirmDelete = false
    }

    private func form(_ p: Binding<ProjectConfig>) -> some View {
        VStack(spacing: 0) {
            Form {
                Section("Project") {
                    TextField("Name", text: p.name)
                    HStack {
                        Text(p.wrappedValue.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Change…") { chooseFolder(p) }
                    }
                    if !model.isGitRepo(p.wrappedValue) {
                        Label("This folder is not a git repository. Run `git init` first; Servant commits its work.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Enabled (included when Claude works on projects)", isOn: p.enabled)
                }

                Section {
                    TextField("Command", text: $devCommandText, prompt: Text("npm run dev -- -p {{PORT}}"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Port", text: $portText, prompt: Text("3123"))
                } header: {
                    Text("Dev server & screenshots")
                } footer: {
                    Text("Optional. When set, Servant starts the server, and Claude takes before/after screenshots with headless Chrome. {{PORT}} is replaced and $PORT is set. Leave the command empty for libraries, CLIs, etc.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: p.prompt)
                        .font(.body)
                        .frame(minHeight: 110)
                    Button("Reset to default task") { p.wrappedValue.prompt = ProjectConfig.defaultTask }
                        .font(.caption)
                } header: {
                    Text("What should Claude work on?")
                } footer: {
                    Text("Servant automatically adds the rules: screenshot, verify with lint/test/build, log to SERVANT_LOG.md, commit.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Git") {
                    Toggle("Skip the project if it has uncommitted changes (recommended)", isOn: p.requireCleanTree)
                    Toggle("Push after committing", isOn: p.autoPush)
                }

                Section {
                    TextEditor(text: $extraToolsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 50)
                } header: {
                    Text("Extra allowed commands")
                } footer: {
                    Text("One permission rule per line, e.g. Bash(pytest:*) or Bash(cargo test:*). Everything not allowed is denied automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if confirmDelete {
                    Text("Remove from Servant? (Files are not touched.)").font(.caption)
                    Button("Remove", role: .destructive) {
                        model.removeProject(id: p.wrappedValue.id)
                        dismissWindow(id: "project-editor")
                    }
                    Button("Cancel") { confirmDelete = false }
                } else {
                    Button("Remove project…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismissWindow(id: "project-editor") }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save(p.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
    }

    private func chooseFolder(_ p: Binding<ProjectConfig>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: p.wrappedValue.expandedPath)
        if panel.runModal() == .OK, let url = panel.url {
            p.wrappedValue.path = Paths.abbreviate(url.path)
        }
    }

    private func save(_ p: ProjectConfig) {
        var p = p
        let cmd = devCommandText.split(separator: " ").map(String.init)
        p.devCommand = cmd.isEmpty ? nil : cmd
        p.devPort = Int(portText.trimmingCharacters(in: .whitespaces)) ?? (cmd.isEmpty ? nil : 3123)
        let tools = extraToolsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.extraAllowedTools = tools.isEmpty ? nil : tools
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty { p.name = URL(fileURLWithPath: p.expandedPath).lastPathComponent }
        model.updateProject(p)
        dismissWindow(id: "project-editor")
    }
}
