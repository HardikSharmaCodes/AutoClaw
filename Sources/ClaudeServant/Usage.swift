import Foundation

/// Usage data captured by the status-line hook (~/.claude/servant/usage.json).
struct UsageSnapshot {
    var fiveHourPct: Double?
    var fiveHourResetsAt: Date?
    var sevenDayPct: Double?
    var sevenDayResetsAt: Date?
    var updatedAt: Date
}

enum UsageReader {
    static func read() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: Paths.usage),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any] else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: Paths.usage.path)[.modificationDate] as? Date) ?? Date()
        let five = rl["five_hour"] as? [String: Any]
        let week = rl["seven_day"] as? [String: Any]
        return UsageSnapshot(
            fiveHourPct: number(five?["used_percentage"]),
            fiveHourResetsAt: date(five?["resets_at"]),
            sevenDayPct: number(week?["used_percentage"]),
            sevenDayResetsAt: date(week?["resets_at"]),
            updatedAt: mtime)
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func date(_ v: Any?) -> Date? {
        if let n = number(v) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Recent Claude Code sessions, read from ~/.claude/projects/*/*.jsonl.
struct SessionInfo: Identifiable {
    var id: String
    var project: String
    var cwd: String
    var lastActivity: Date
}

enum SessionTracker {
    private static var cwdCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    static func recent(within hours: Double = 24) -> [SessionInfo] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        guard let dirs = try? fm.contentsOfDirectory(at: Paths.claudeProjects, includingPropertiesForKeys: nil) else { return [] }
        var out: [SessionInfo] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > cutoff else { continue }
                let cwd = cwdFor(f) ?? dir.lastPathComponent
                out.append(SessionInfo(id: f.deletingPathExtension().lastPathComponent,
                                       project: (cwd as NSString).lastPathComponent,
                                       cwd: cwd, lastActivity: m))
            }
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    private static func cwdFor(_ url: URL) -> String? {
        cacheLock.lock(); let cached = cwdCache[url.path]; cacheLock.unlock()
        if let c = cached { return c }
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 256 * 1024), as: UTF8.self)
        guard let r = head.range(of: #""cwd":"([^"]+)""#, options: .regularExpression) else { return nil }
        let cwd = String(String(head[r]).dropFirst("\"cwd\":\"".count).dropLast())
        cacheLock.lock(); cwdCache[url.path] = cwd; cacheLock.unlock()
        return cwd
    }
}
