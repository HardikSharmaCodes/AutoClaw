import Foundation

/// Runs one unattended Claude Code job on a project:
/// git safety check → start dev server → `claude -p` with a scoped allowlist → stop server → verify commit/push.
final class ProjectRunner: @unchecked Sendable {
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
    private var _cancelled = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

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
        lock.lock(); _cancelled = true; let ps = processes; lock.unlock()
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
        let safeName = Self.safeName(project.name)
        let logURL = Paths.logs.appendingPathComponent("\(safeName)-\(stamp).log")
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
        let wasClean = status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dirtyList = wasClean ? "" : status.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let headBefore = await sh(["git", "rev-parse", "HEAD"], cwd: dir)
        let before = headBefore.code == 0 ? headBefore.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""

        // Dev server
        var server: Process?
        let port = project.devPort ?? 3123
        if let cmd = project.devCommand, !cmd.isEmpty {
            if await urlUp(port, timeout: 3) {
                log("Port \(port) already serving – reusing it")
            } else {
                log("Starting dev server: \(cmd.joined(separator: " ")) (port \(port))")
                server = spawn(cmd.map { $0.replacingOccurrences(of: "{{PORT}}", with: "\(port)") }, cwd: dir, port: port)
                var up = false
                for _ in 0..<90 where !cancelled {
                    guard let srv = server, srv.isRunning else { break }   // failed to spawn or exited early
                    if await urlUp(port, timeout: 3) { up = true; break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard up else {
                    await stopServer(server, port: port)
                    outcome.headline = "dev server did not start"; log(outcome.headline); return outcome
                }
                _ = await urlUp(port, timeout: 90)   // warm up: first Next.js request compiles the page
                log("Dev server is up")
            }
        }

        let shotDir = Paths.screenshots.appendingPathComponent(safeName).path
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
        let prompt = Self.buildPrompt(project: project, port: port, stamp: stamp, shotDir: shotDir, preexistingChanges: dirtyList)
        let tools = (config.baseAllowedTools + (project.extraAllowedTools ?? []))
            .map { $0.replacingOccurrences(of: "~/", with: Paths.home.path + "/") }

        log("Launching Claude…")
        let result = cancelled ? ClaudeResult() : await runClaude(prompt: prompt, tools: tools, cwd: dir, extraDir: shotDir)
        if server != nil { await stopServer(server, port: port) }

        let headAfter = await sh(["git", "rev-parse", "HEAD"], cwd: dir)
        let after = headAfter.code == 0 ? headAfter.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        outcome.committed = !after.isEmpty && after != before
        var pushNote = ""
        if outcome.committed {
            let ahead = await sh(["git", "rev-list", "--count", "@{u}..HEAD"], cwd: dir)
            if ahead.code != 0 { pushNote = "no upstream branch" }
            else { outcome.pushed = ahead.out.trimmingCharacters(in: .whitespacesAndNewlines) == "0" }
        } else if wasClean {
            // The tree was clean before the run, so anything left over is Claude's abandoned work
            // (e.g. SERVANT_LOG.md after a `git restore`). Remove it so the next run isn't skipped.
            let left = await sh(["git", "status", "--porcelain"], cwd: dir)
            if left.code == 0, !left.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("Cleaning up uncommitted leftovers from this run")
                _ = await sh(["git", "checkout", "--", "."], cwd: dir)
                _ = await sh(["git", "clean", "-fd"], cwd: dir)
            }
        }
        outcome.hitLimit = result.hitLimit

        if cancelled { outcome.headline = "stopped by you" }
        else if result.hitLimit { outcome.headline = "paused – usage limit reached" }
        else if outcome.pushed { outcome.headline = "improved, committed and pushed ✅" }
        else if outcome.committed && !project.autoPush { outcome.headline = "improved and committed (push is off)" }
        else if outcome.committed { outcome.headline = "committed but NOT pushed ⚠️" + (pushNote.isEmpty ? "" : " (\(pushNote))") }
        else { outcome.headline = result.isError ? "Claude reported an error" : "finished without a commit" }
        if let text = result.text, !text.isEmpty { log("Claude's summary:\n" + text) }
        log("Result: \(outcome.headline)")
        return outcome
    }

    // MARK: - Claude

    private struct ClaudeResult { var text: String?; var isError = false; var hitLimit = false }

    private func runClaude(prompt: String, tools: [String], cwd: String, extraDir: String) async -> ClaudeResult {
        guard let claude = Paths.resolveClaude(config.claudePath) else {
            log("Could not find the `claude` CLI. Install Claude Code or set claudePath in config.json.")
            return ClaudeResult(text: nil, isError: true)
        }
        var args = [claude, "-p", prompt,
                    "--output-format", "stream-json", "--verbose",
                    "--permission-mode", "acceptEdits",
                    "--max-turns", "\(config.maxTurns)",
                    "--add-dir", extraDir]
        if !tools.isEmpty { args += ["--allowedTools"] + tools }
        return await withCheckedContinuation { cont in
            let p = makeProcess(args, cwd: cwd)
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let fh = pipe.fileHandleForReading
            let q = DispatchQueue(label: "servant.claude-output")
            var result = ClaudeResult()
            var sawNonJSONLimit = false
            var buffer = Data()
            var finished = false

            func consume(_ line: Data) {
                if (try? JSONSerialization.jsonObject(with: line)) == nil {
                    let s = String(decoding: line, as: UTF8.self)
                    if Self.looksLikeLimit(s) { sawNonJSONLimit = true }
                }
                self.handle(line: line, into: &result)
            }
            func drain() {
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<nl])
                    buffer.removeSubrange(buffer.startIndex...nl)
                    consume(line)
                }
            }
            func finish(_ status: Int32) {
                guard !finished else { return }
                finished = true
                fh.readabilityHandler = nil
                drain()
                if !buffer.isEmpty { consume(buffer); buffer.removeAll() }   // last line without trailing newline
                if status != 0 && result.text == nil {
                    result.isError = true
                    if sawNonJSONLimit { result.hitLimit = true }
                }
                cont.resume(returning: result)
            }

            // Read via a handler and finish on process exit, not on EOF: background processes that
            // Claude starts can inherit the pipe and keep it open forever.
            fh.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; return }
                q.async {
                    self.logHandle?.write(chunk)
                    buffer.append(chunk)
                    drain()
                }
            }
            p.terminationHandler = { proc in
                // Give already-queued output a moment to be processed before finishing.
                q.asyncAfter(deadline: .now() + 0.3) { finish(proc.terminationStatus) }
            }
            do { try p.run() } catch {
                fh.readabilityHandler = nil
                self.log("Could not start claude: \(error)")
                cont.resume(returning: ClaudeResult(text: nil, isError: true)); return
            }
            self.track(p)
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
            if !s.isEmpty { emit(s) }
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

    private func urlUp(_ port: Int, timeout: TimeInterval) async -> Bool {
        var req = URLRequest(url: URL(string: "http://localhost:\(port)/")!)
        req.timeoutInterval = timeout
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    /// Wraps the project's task with the rules every unattended run follows.
    static func buildPrompt(project: ProjectConfig, port: Int, stamp: String, shotDir: String, preexistingChanges: String) -> String {
        var steps: [String] = []
        let shot = Paths.screenshotTool.path
        if project.hasDevServer {
            steps.append("The dev server is already running at http://localhost:\(port). Take a BEFORE screenshot: `\(shot) http://localhost:\(port) \(shotDir)/\(stamp)-before.png` (optional extra args: width height wait_ms, e.g. 390 844 for mobile). Read the PNG to see what users see. Screenshots are stored outside the repo; never add them to git.")
        }
        steps.append("Read SERVANT_LOG.md if it exists so you don't repeat earlier runs, then study the code.")
        steps.append("Do the TASK. Keep the scope small enough to finish and verify in this run.")
        if project.hasDevServer {
            steps.append("Verify: run the project's lint and test scripts (e.g. `npm run lint`, `npm test`) and fix anything you broke. Do NOT run `npm run build` while the dev server is running; it shares the build folder and would break the running server. Use a type check (`npx --no-install tsc --noEmit`) instead.")
            steps.append("Take an AFTER screenshot to \(shotDir)/\(stamp)-after.png and compare it with the before shot.")
        } else {
            steps.append("Verify: run whatever lint/test/build scripts the project has (e.g. `npm run lint`, `npm run build`, `npm test`) and fix anything you broke.")
        }
        steps.append("Append an entry to SERVANT_LOG.md: date, what you changed and why, how you verified it, ideas for next time.")
        steps.append("`git add` ONLY the files you changed and SERVANT_LOG.md (name each file explicitly; never `git add .`/`-A` and never `git commit -a`), then commit with a clear message." + (project.autoPush ? " Then `git push` (plain, no flags)." : " Do NOT push."))
        let numbered = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        var protect = ""
        if !preexistingChanges.isEmpty {
            protect = """

            PROTECTED: the user already has uncommitted work in this repo. Do NOT modify, stage, commit, restore or delete any of these paths:
            \(preexistingChanges)
            """
        }
        return """
        You are running UNATTENDED, launched by Claude Servant. Nobody can answer questions, so make sensible decisions yourself and finish the job.

        Project: \(project.name)

        TASK:
        \(project.prompt)
        \(protect)

        STEPS:
        \(numbered)

        If verification fails and you cannot fix it, undo ONLY your own changes (`git restore <file>` for files you edited, and delete files you created) and do not commit; explain why. Finish with a short summary of what you did.
        """
    }

    static func safeName(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? String($0) : "_" }.joined()
        return cleaned.isEmpty ? "project" : cleaned
    }

    static func stamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }
}
