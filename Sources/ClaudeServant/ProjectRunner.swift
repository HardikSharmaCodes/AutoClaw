import Foundation

/// Runs one unattended Claude Code job on a project:
/// git safety check → start dev server → `claude -p` with a scoped allowlist → stop server → verify commit/push.
final class ProjectRunner {
    struct Outcome {
        var headline: String
        var hitLimit = false
        var committed = false
        var pushed = false
        var logPath: String?
    }

    let config: ServantConfig
    let project: ProjectConfig
    private let emit: (String) -> Void
    private var processes: [Process] = []
    private let lock = NSLock()
    private var logHandle: FileHandle?
    private(set) var cancelled = false

    init(config: ServantConfig, project: ProjectConfig, log: @escaping (String) -> Void) {
        self.config = config
        self.project = project
        self.emit = log
    }

    private lazy var env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        let home = Paths.home.path
        e["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", e["PATH"] ?? ""].joined(separator: ":")
        e["GIT_TERMINAL_PROMPT"] = "0"
        return e
    }()

    func cancel() {
        cancelled = true
        lock.lock(); let ps = processes; lock.unlock()
        ps.forEach { if $0.isRunning { $0.terminate() } }
    }

    private func log(_ s: String) {
        emit(s)
        logHandle?.write(Data(("[servant] " + s + "\n").utf8))
    }

    // MARK: - Main flow

    func run() async -> Outcome {
        Paths.ensureDirs()
        let stamp = Self.stamp()
        let logURL = Paths.logs.appendingPathComponent("\(project.name)-\(stamp).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        var outcome = Outcome(headline: "", logPath: logURL.path)

        let dir = Paths.expand(project.path)
        guard FileManager.default.fileExists(atPath: dir) else {
            outcome.headline = "folder not found: \(dir)"; log(outcome.headline); return outcome
        }
        let status = await sh(["git", "status", "--porcelain"], cwd: dir)
        guard status.code == 0 else { outcome.headline = "not a git repository"; log(outcome.headline); return outcome }
        if project.requireCleanTree && !status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outcome.headline = "skipped – you have uncommitted changes (commit or stash them first)"
            log(outcome.headline); log(status.out); return outcome
        }
        let before = await sh(["git", "rev-parse", "HEAD"], cwd: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dev server
        var server: Process?
        let port = project.devPort ?? 3000
        if let cmd = project.devCommand, !cmd.isEmpty {
            if await urlUp(port) {
                log("Port \(port) already serving – reusing it")
            } else {
                log("Starting dev server: \(cmd.joined(separator: " ")) (port \(port))")
                server = spawn(cmd.map { $0.replacingOccurrences(of: "{{PORT}}", with: "\(port)") }, cwd: dir, port: port)
                var up = false
                for _ in 0..<90 where !cancelled {
                    if await urlUp(port) { up = true; break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard up else {
                    await stopServer(server, port: port)
                    outcome.headline = "dev server did not start"; log(outcome.headline); return outcome
                }
                log("Dev server is up")
            }
        }

        let prompt = Self.buildPrompt(project: project, port: port, stamp: stamp)
        let tools = (config.baseAllowedTools + (project.extraAllowedTools ?? []))
            .map { $0.replacingOccurrences(of: "~/", with: Paths.home.path + "/") }

        log("Launching Claude…")
        let result = cancelled ? ClaudeResult() : await runClaude(prompt: prompt, tools: tools, cwd: dir)
        if server != nil { await stopServer(server, port: port) }

        let after = await sh(["git", "rev-parse", "HEAD"], cwd: dir).out.trimmingCharacters(in: .whitespacesAndNewlines)
        outcome.committed = !after.isEmpty && after != before
        let ahead = await sh(["git", "rev-list", "--count", "@{u}..HEAD"], cwd: dir)
        outcome.pushed = outcome.committed && ahead.code == 0 && ahead.out.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
        outcome.hitLimit = result.hitLimit

        if cancelled { outcome.headline = "stopped by you" }
        else if result.hitLimit { outcome.headline = "paused – usage limit reached" }
        else if outcome.pushed { outcome.headline = "improved, committed and pushed ✅" }
        else if outcome.committed { outcome.headline = "committed but NOT pushed ⚠️" }
        else { outcome.headline = result.isError ? "Claude reported an error" : "finished without a commit" }
        if let text = result.text, !text.isEmpty { log("Claude's summary:\n" + text) }
        log("Result: \(outcome.headline)")
        return outcome
    }

    // MARK: - Claude

    private struct ClaudeResult { var text: String?; var isError = false; var hitLimit = false }

    private func runClaude(prompt: String, tools: [String], cwd: String) async -> ClaudeResult {
        guard let claude = Paths.resolveClaude(config.claudePath) else {
            log("Could not find the `claude` CLI. Install Claude Code or set claudePath in config.json.")
            return ClaudeResult(text: nil, isError: true)
        }
        let args = [claude, "-p", prompt,
                    "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "acceptEdits",
                    "--max-turns", "\(config.maxTurns)",
                    "--allowedTools"] + tools
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var result = ClaudeResult()
                let p = self.makeProcess(args, cwd: cwd)
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch {
                    self.log("Could not start claude: \(error)")
                    cont.resume(returning: ClaudeResult(text: nil, isError: true)); return
                }
                self.track(p)
                var buffer = Data()
                let fh = pipe.fileHandleForReading
                while true {
                    let chunk = fh.availableData
                    if chunk.isEmpty { break }
                    self.logHandle?.write(chunk)
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let line = Data(buffer[buffer.startIndex..<nl])
                        buffer.removeSubrange(buffer.startIndex...nl)
                        self.handle(line: line, into: &result)
                    }
                }
                p.waitUntilExit()
                if p.terminationStatus != 0 && result.text == nil { result.isError = true }
                cont.resume(returning: result)
            }
        }
    }

    private static func looksLikeLimit(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("usage limit") || l.contains("limit reached") || l.contains("hit your limit")
            || l.contains("rate_limit_error") || l.contains("limit will reset")
    }

    private func handle(line: Data, into result: inout ClaudeResult) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            let s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { emit(s); if Self.looksLikeLimit(s) { result.hitLimit = true } }
            return
        }
        switch obj["type"] as? String {
        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for c in content {
                if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty {
                    emit("💬 " + String(t.prefix(240)))
                } else if c["type"] as? String == "tool_use" {
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any] ?? [:]
                    let detail = (input["command"] ?? input["file_path"] ?? input["pattern"] ?? input["description"]) as? String ?? ""
                    emit("🔧 \(name) \(detail.prefix(160))")
                }
            }
            if obj["error"] != nil, Self.looksLikeLimit(String(decoding: line, as: UTF8.self)) { result.hitLimit = true }
        case "result":
            result.text = obj["result"] as? String
            result.isError = obj["is_error"] as? Bool ?? false
            if result.isError, Self.looksLikeLimit(String(decoding: line, as: UTF8.self)) { result.hitLimit = true }
        case "system":
            if obj["subtype"] as? String == "init" { emit("Claude session started") }
        default: break
        }
    }

    // MARK: - Process helpers

    private func makeProcess(_ args: [String], cwd: String) -> Process {
        let p = Process()
        if args[0].hasPrefix("/") {
            p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
        }
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        return p
    }

    private func track(_ p: Process) { lock.lock(); processes.append(p); lock.unlock() }

    private func spawn(_ args: [String], cwd: String, port: Int) -> Process? {
        let p = makeProcess(args, cwd: cwd)
        p.environment?["PORT"] = "\(port)"
        p.environment?["BROWSER"] = "none"
        if let h = logHandle { p.standardOutput = h; p.standardError = h }
        do { try p.run(); track(p); return p } catch { log("Failed to start \(args[0]): \(error)"); return nil }
    }

    func sh(_ args: [String], cwd: String) async -> (code: Int32, out: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = self.makeProcess(args, cwd: cwd)
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { cont.resume(returning: (-1, "\(error)")); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    private func stopServer(_ p: Process?, port: Int) async {
        p?.terminate()
        // npm/next spawn children; make sure whatever listens on our port goes away.
        _ = await sh(["/bin/sh", "-c", "lsof -ti tcp:\(port) -sTCP:LISTEN | xargs kill 2>/dev/null; true"], cwd: "/")
        log("Dev server stopped")
    }

    private func urlUp(_ port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:\(port)/")!)
        req.timeoutInterval = 60  // first Next.js request compiles the page
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    /// Wraps the project's task with the rules every unattended run follows.
    static func buildPrompt(project: ProjectConfig, port: Int, stamp: String) -> String {
        var steps: [String] = []
        let shot = Paths.screenshotTool.path
        let dir = "docs/servant-screenshots"
        if project.hasDevServer {
            steps.append("The dev server is already running at http://localhost:\(port). Take a BEFORE screenshot: `\(shot) http://localhost:\(port) \(dir)/\(stamp)-before.png` (optional extra args: width height wait_ms, e.g. 390 844 for mobile). Read the PNG to see what users see.")
        }
        steps.append("Read SERVANT_LOG.md if it exists so you don't repeat earlier runs, then study the code.")
        steps.append("Do the TASK. Keep the scope small enough to finish and verify in this run.")
        steps.append("Verify: run whatever lint/test/build scripts the project has (e.g. `npm run lint`, `npm run build`, `npm test`) and fix anything you broke.")
        if project.hasDevServer {
            steps.append("Take an AFTER screenshot to \(dir)/\(stamp)-after.png and compare it with the before shot.")
        }
        steps.append("Append an entry to SERVANT_LOG.md: date, what you changed and why, how you verified it, ideas for next time.")
        let addWhat = project.hasDevServer ? "the files you changed, the new screenshots and SERVANT_LOG.md" : "the files you changed and SERVANT_LOG.md"
        steps.append("`git add` ONLY \(addWhat), then commit with a clear message." + (project.autoPush ? " Then `git push`." : " Do NOT push."))
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return """
        You are running UNATTENDED, launched by Claude Servant. Nobody can answer questions, so make sensible decisions yourself and finish the job.

        Project: \(project.name)

        TASK:
        \(project.prompt)

        STEPS:
        \(numbered)

        If verification fails and you cannot fix it, undo your changes with `git restore` and do not commit; explain why. Finish with a short summary of what you did.
        """
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.string(from: Date())
    }
}
