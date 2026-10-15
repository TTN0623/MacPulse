// Tab Tác vụ: phiên Claude đang làm gì, việc dựng video (ffmpeg, Remotion, Whisper, app dựng phim),
// tiến trình người dùng ghim. Ước tính % và thời gian còn lại khi đo được.
import Foundation
import AVFoundation

struct TaskProgress {
    var fraction: Double?        // 0...1; nil = không đo được
    var eta: TimeInterval?
    var detail: String?
}

struct TaskItem: Identifiable {
    enum Kind { case claude, video, app, ai, pinned, child }
    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var status: String
    var active: Bool
    var startedAt: Date?
    var progress = TaskProgress()
    var iconPath: String?
    var symbol = "gearshape"
    var cpu: Double = 0
    var children: [TaskItem] = []
    var pids: [pid_t] = []
    var ppid: pid_t = 0
    var pipeIn = false        // ffmpeg đọc khung hình từ ống (stdin)
    var pipeOut = false       // ffmpeg ghi khung hình ra ống (stdout)
    var parentScript: String?
}

struct FinishedItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let endedAt: Date
}

struct PinnedProcess {
    let id: String
    let name: String
    let iconPath: String?
    let pids: [pid_t]
    let pinnedAt: Date
}

// MARK: Đọc nhật ký phiên Claude Code (~/.claude/projects/<thư mục>/<phiên>.jsonl)

struct SessionInfo {
    enum State { case unknown, thinking, tool(String), waitingUser, idle }
    var title: String?
    var lastPrompt: String?
    var model: String?
    var effort: String?
    var cwd: String?
    var state: State = .unknown
    var lastActivity: Date?
    var turnStart: Date?
    var toolCalls = 0
    var todoDone = 0
    var todoTotal = 0
    var todoCurrent: String?
    var lastText: String?

    var working: Bool {
        switch state {
        case .thinking, .tool: return true
        default: return false
        }
    }
}

enum TranscriptReader {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    /// Đọc từ cuối file; file có thể nặng hàng trăm MB nên chỉ nới cửa sổ khi chưa đủ thông tin.
    static func read(_ path: String) -> SessionInfo {
        guard let h = FileHandle(forReadingAtPath: path) else { return SessionInfo() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var window: UInt64 = 1 << 20
        while true {
            let start = size > window ? size - window : 0
            try? h.seek(toOffset: start)
            let data = h.readData(ofLength: Int(size - start))
            let (info, enough) = parse(data, cutFirstLine: start > 0)
            if enough || start == 0 || window >= 16 << 20 { return info }
            window *= 4
        }
    }

    private static func parse(_ data: Data, cutFirstLine: Bool) -> (SessionInfo, Bool) {
        var info = SessionInfo()
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if cutFirstLine, !lines.isEmpty { lines.removeFirst() }
        var stateFound = false
        var turnFound = false
        var earliest: Date?
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let ts = date(obj["timestamp"])
            if let ts {
                earliest = ts
                if info.lastActivity == nil { info.lastActivity = ts }
            }
            switch type {
            case "ai-title":
                if info.title == nil { info.title = obj["aiTitle"] as? String }
            case "last-prompt":
                if info.lastPrompt == nil { info.lastPrompt = obj["lastPrompt"] as? String }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any] else { continue }
                if info.model == nil, let m = msg["model"] as? String, m.hasPrefix("claude") {
                    info.model = m
                    info.effort = obj["effort"] as? String
                }
                if info.cwd == nil { info.cwd = obj["cwd"] as? String }
                let content = msg["content"] as? [[String: Any]] ?? []
                let tools = content.filter { $0["type"] as? String == "tool_use" }
                if !turnFound {
                    info.toolCalls += tools.count
                    if info.todoTotal == 0, let todo = tools.last(where: { $0["name"] as? String == "TodoWrite" }),
                       let todos = (todo["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                        info.todoTotal = todos.count
                        info.todoDone = todos.filter { $0["status"] as? String == "completed" }.count
                        info.todoCurrent = todos.first { $0["status"] as? String == "in_progress" }
                            .flatMap { ($0["activeForm"] as? String) ?? ($0["content"] as? String) }
                    }
                }
                if !stateFound {
                    stateFound = true
                    if let t = tools.last {
                        let name = t["name"] as? String ?? "?"
                        if name == "AskUserQuestion" || name == "ExitPlanMode" {
                            info.state = .waitingUser
                        } else {
                            info.state = .tool(describe(tool: name, input: t["input"] as? [String: Any] ?? [:]))
                        }
                    } else if msg["stop_reason"] as? String == "end_turn" {
                        info.state = .idle
                        info.lastText = content.compactMap { $0["text"] as? String }.last
                    } else {
                        info.state = .thinking
                    }
                }
            case "user":
                if obj["isMeta"] as? Bool == true { continue }
                let msg = obj["message"] as? [String: Any]
                var isPrompt = false
                if let c = msg?["content"] as? String {
                    isPrompt = !c.hasPrefix("<") || c.hasPrefix("<task-notification>")
                } else if let arr = msg?["content"] as? [[String: Any]] {
                    isPrompt = !arr.contains { $0["type"] as? String == "tool_result" } && arr.contains { $0["type"] as? String == "text" }
                }
                if !stateFound {
                    stateFound = true
                    info.state = .thinking
                }
                if isPrompt && !turnFound {
                    turnFound = true
                    info.turnStart = ts
                }
            default:
                break
            }
            let turnKnown = turnFound || { if case .idle = info.state { return true } else { return false } }()
            if stateFound && turnKnown && info.title != nil && info.model != nil { return (info, true) }
        }
        if info.turnStart == nil { info.turnStart = earliest }
        return (info, false)
    }

    /// Mô tả công cụ đang chạy bằng tiếng Việt, kèm chi tiết ngắn.
    static func describe(tool: String, input: [String: Any]) -> String {
        func s(_ k: String) -> String? {
            guard let v = input[k] as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        func file(_ k: String) -> String { s(k).map { ($0 as NSString).lastPathComponent } ?? "" }
        func firstLine(_ v: String?) -> String { String((v ?? "").split(separator: "\n").first ?? "").prefix(90).description }
        switch tool {
        case "Bash": return "Chạy lệnh: " + (s("description") ?? firstLine(s("command")))
        case "Read": return "Đọc " + file("file_path")
        case "Edit", "MultiEdit": return "Sửa " + file("file_path")
        case "Write": return "Ghi " + file("file_path")
        case "NotebookEdit": return "Sửa notebook " + file("notebook_path")
        case "Grep", "Glob": return "Tìm trong mã: " + (s("pattern") ?? "")
        case "Agent", "Task": return "Giao subagent: " + (s("description") ?? "")
        case "WebSearch": return "Tìm web: " + (s("query") ?? "")
        case "WebFetch": return "Mở trang: " + (s("url").flatMap { URL(string: $0)?.host } ?? "")
        case "Skill": return "Dùng skill " + (s("skill") ?? "")
        case "Workflow": return "Chạy workflow nhiều agent"
        case "Monitor": return "Theo dõi: " + (s("description") ?? "")
        case "TodoWrite": return "Cập nhật danh sách việc"
        case "ScheduleWakeup": return "Hẹn giờ tự gọi lại"
        default:
            if tool.hasPrefix("mcp__") { return "Công cụ " + (tool.components(separatedBy: "__").last ?? tool) }
            return "Công cụ " + tool
        }
    }

    /// "claude-opus-5-5" -> "Opus 5.5", "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"
    static func modelName(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && Int($0) != nil) }
        guard let first = parts.first else { return id }
        if Int(first) == nil { return ([first.capitalized] + [parts.dropFirst().joined(separator: ".")]).joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        let nums = parts.prefix { Int($0) != nil }
        let rest = parts.dropFirst(nums.count).map { $0.capitalized }
        return (nums.joined(separator: ".") + " " + rest.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: Ước tính tiến độ ffmpeg qua vị trí đang đọc file nguồn

enum FFmpegProbe {
    struct Input {
        var path: String
        var ss: Double?
        var t: Double?
        var to: Double?
        var isConcat = false
        var trimEnd: Double?
        var trimOpen = false
    }

    static func parseTime(_ s: String) -> Double? {
        if let v = Double(s) { return v }
        let trimmed = s.hasSuffix("s") ? String(s.dropLast()) : s
        if let v = Double(trimmed) { return v }
        let parts = s.split(separator: ":").map { Double($0) }
        guard parts.count >= 2, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// "-" hoặc "pipe:0/1": dữ liệu đi qua ống giữa các tiến trình, không phải file.
    static func isPipe(_ p: String) -> Bool { p == "-" || p.hasPrefix("pipe:") }

    static func parse(_ args: [String], cwd: String?) -> (inputs: [Input], output: String?, outT: Double?) {
        var inputs: [Input] = []
        var ss: Double?, t: Double?, to: Double?, format: String?
        var filters: [String] = []
        var i = 1
        func resolve(_ p: String) -> String {
            if p.hasPrefix("/") || cwd == nil || FFmpegProbe.isPipe(p) { return p }
            return (cwd! as NSString).appendingPathComponent(p)
        }
        while i < args.count {
            let a = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch a {
            case "-i":
                if let p = next {
                    inputs.append(Input(path: resolve(p), ss: ss, t: t, to: to, isConcat: format == "concat"))
                }
                ss = nil; t = nil; to = nil; format = nil
                i += 2; continue
            case "-ss": ss = next.flatMap(parseTime)
            case "-t": t = next.flatMap(parseTime)
            case "-to": to = next.flatMap(parseTime)
            case "-f": format = next
            case "-filter_complex", "-lavfi", "-vf", "-af", "-filter:v", "-filter:a":
                if let n = next { filters.append(n) }
            default:
                i += 1; continue
            }
            i += 2
        }
        let outT = t   // -t nằm sau input cuối là giới hạn độ dài đầu ra
        var output: String?
        if let last = args.last, FFmpegProbe.isPipe(last) {
            output = last
        } else if let last = args.last, !last.hasPrefix("-") {
            let full = resolve(last)
            if !inputs.contains(where: { inp in inp.path == full }) { output = full }
        }

        // trim/atrim trong bộ lọc: lấy mốc cuối lớn nhất cho từng input.
        let regex = try! NSRegularExpression(pattern: #"(?:\[(\d+):[^\]]*\]\s*)?a?trim=([^,;\[]+)"#)
        for f in filters {
            let ns = f as NSString
            for m in regex.matches(in: f, range: NSRange(location: 0, length: ns.length)) {
                let idx = m.range(at: 1).location != NSNotFound ? Int(ns.substring(with: m.range(at: 1))) : (inputs.count == 1 ? 0 : nil)
                guard let idx, idx < inputs.count else { continue }
                let params = ns.substring(with: m.range(at: 2)).split(separator: ":").map(String.init)
                var start: Double?, end: Double?, dur: Double?
                if params.contains(where: { $0.contains("=") }) {
                    for p in params {
                        let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
                        guard kv.count == 2 else { continue }
                        switch kv[0] {
                        case "start", "starti": start = parseTime(kv[1])
                        case "end", "endi": end = parseTime(kv[1])
                        case "duration", "durationi": dur = parseTime(kv[1])
                        default: break
                        }
                    }
                } else {
                    start = params.first.flatMap(parseTime)
                    end = params.count > 1 ? parseTime(params[1]) : nil
                }
                if end == nil, let s0 = start, let d = dur { end = s0 + d }
                if let e = end {
                    inputs[idx].trimEnd = max(inputs[idx].trimEnd ?? 0, e)
                } else {
                    inputs[idx].trimOpen = true
                }
            }
        }
        return (inputs, output, outT)
    }

    /// Trả về (đã đọc, cần đọc) theo byte cùng mô tả ngắn.
    static func progress(inputs: [Input], outT: Double?, files: [ProcInfo.OpenFile],
                         duration: (String, Int64) -> Double?) -> (done: Double, total: Double, detail: String?)? {
        var done = 0.0, total = 0.0
        var detail: String?
        for inp in inputs {
            if inp.isConcat {
                guard let list = try? String(contentsOfFile: inp.path, encoding: .utf8) else { continue }
                let dir = (inp.path as NSString).deletingLastPathComponent
                let entries: [String] = list.split(separator: "\n").compactMap { line in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    guard l.hasPrefix("file ") else { return nil }
                    var p = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    if p.hasPrefix("'"), p.hasSuffix("'"), p.count >= 2 { p = String(p.dropFirst().dropLast()) }
                    return p.hasPrefix("/") ? p : (dir as NSString).appendingPathComponent(p)
                }
                let sizes = entries.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64) ?? 0 }
                guard let cur = entries.firstIndex(where: { e in files.contains { ProcInfo.samePath($0.path, e) && $0.readable } }) else { continue }
                let off = files.first { ProcInfo.samePath($0.path, entries[cur]) }?.offset ?? 0
                done += Double(sizes[..<cur].reduce(0, +) + off)
                total += Double(sizes.reduce(0, +))
                detail = "File \(cur + 1)/\(entries.count) trong danh sách ghép"
                continue
            }
            guard let f = files.first(where: { $0.readable && ProcInfo.samePath($0.path, inp.path) }), f.size > 0 else { continue }
            let size = Double(f.size)
            var startB = 0.0, endB = size
            if let dur = duration(inp.path, f.size), dur > 0 {
                let start = inp.ss ?? 0
                var ends: [Double] = []
                if let to = inp.to { ends.append(to) }
                if let t = inp.t { ends.append(start + t) }
                if let te = inp.trimEnd, !inp.trimOpen { ends.append(start + te) }
                if let ot = outT { ends.append(start + ot) }
                let end = min(dur, ends.min() ?? dur)
                startB = size * start / dur
                endB = max(startB + 1, size * end / dur)
                let pos = Double(f.offset) / size * dur
                detail = "Đang đọc tới \(clock(pos)) / cần tới \(clock(end)) của video nguồn"
            } else {
                detail = "Đã đọc \(Fmt.bytes(Double(f.offset))) / \(Fmt.bytes(size))"
            }
            done += min(max(Double(f.offset) - startB, 0), endB - startB)
            total += endB - startB
        }
        return total > 0 ? (done, total, detail) : nil
    }

    static func clock(_ s: Double) -> String {
        let v = Int(s.rounded())
        return v >= 3600 ? String(format: "%d:%02d:%02d", v / 3600, v / 60 % 60, v % 60) : String(format: "%d:%02d", v / 60, v % 60)
    }
}

// MARK: Bộ theo dõi

final class TaskTracker: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []          // việc đang chạy
    @Published private(set) var waiting: [TaskItem] = []        // phiên Claude đang chờ bạn
    @Published private(set) var finished: [FinishedItem] = []
    @Published private(set) var hasActive = false
    @Published private(set) var activeNames: [String] = []
    @Published private(set) var lastScan: Date?
    @Published private(set) var pins: [PinnedProcess] = []

    private let queue = DispatchQueue(label: "macpulse.tasks", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var visible = false
    private var background = false
    private var interval: TimeInterval = 0

    // Chỉ đụng tới trên queue
    private var pinsQ: [PinnedProcess] = []
    private var history: [String: [(Date, Double)]] = [:]
    private var sizeHistory: [String: [(Date, Int64)]] = [:]
    private var durations: [String: Double] = [:]
    private var sessionCache: [String: (mtime: Date, size: Int64, info: SessionInfo)] = [:]
    private var prevActive: [String: (title: String, start: Date?)] = [:]
    private var lastScanQ: Date?
    private var scanCount = 0

    private let projectsDir = NSHomeDirectory() + "/.claude/projects"
    private let claudeIcon: String? = FileManager.default.fileExists(atPath: "/Applications/Claude.app") ? "/Applications/Claude.app" : nil

    static let videoApps: [String: String] = [
        "CapCut": "CapCut", "Final Cut Pro": "Final Cut Pro", "Compressor": "Compressor", "Motion": "Motion",
        "DaVinci Resolve": "DaVinci Resolve", "HandBrake": "HandBrake", "iMovie": "iMovie",
        "Topaz Video AI": "Topaz Video AI", "Topaz Video": "Topaz Video",
    ]
    static let videoAppPrefixes = ["Adobe Premiere Pro", "Adobe Media Encoder", "Adobe After Effects"]
    static let aiAgents: [String: String] = ["codex": "Codex CLI", "gemini": "Gemini CLI", "aider": "Aider", "cursor-agent": "Cursor Agent", "goose": "Goose"]

    /// Đang xem tab Tác vụ: quét 3 giây/lần.
    func setVisible(_ on: Bool) {
        queue.async { self.visible = on; self.reschedule() }
    }

    /// Chế độ "tắt khi xong việc" cần biết còn việc không, kể cả khi bảng đóng: 15 giây/lần.
    func setBackground(_ on: Bool) {
        queue.async { self.background = on; self.reschedule() }
    }

    func pin(_ row: ProcessRow) {
        let p = PinnedProcess(id: "pin-" + row.id, name: row.name, iconPath: row.iconPath, pids: row.pids, pinnedAt: Date())
        queue.async {
            self.pinsQ.removeAll { $0.id == p.id }
            self.pinsQ.append(p)
            self.scan()
        }
    }

    func unpin(_ id: String) {
        queue.async {
            self.pinsQ.removeAll { $0.id == id }
            self.scan()
        }
    }

    func clearFinished() { finished = [] }

    private func reschedule() {
        let want: TimeInterval = visible ? 3 : (background ? 15 : 0)
        guard want != interval else { if want > 0 { scan() }; return }
        interval = want
        timer?.cancel()
        timer = nil
        guard want > 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: want, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    // MARK: Quét

    private func scan() {
        let now = Date()
        scanCount += 1
        let procs = ProcessSampler.raw()
        var byPid: [pid_t: ProcessSampler.Raw] = [:]
        var kids: [pid_t: [pid_t]] = [:]
        for p in procs {
            byPid[p.pid] = p
            kids[p.ppid, default: []].append(p.pid)
        }
        let me = NSUserName()
        var argsCache: [pid_t: [String]] = [:]
        func args(_ pid: pid_t) -> [String] {
            if let a = argsCache[pid] { return a }
            let a = ProcInfo.args(pid) ?? []
            argsCache[pid] = a
            return a
        }
        func ancestors(_ pid: pid_t) -> [pid_t] {
            var out: [pid_t] = []
            var cur = byPid[pid]?.ppid ?? 1
            while cur > 1, out.count < 30, let p = byPid[cur] { out.append(cur); cur = p.ppid }
            return out
        }
        func hostApp(_ pid: pid_t) -> String? {
            for a in ancestors(pid) {
                if let app = byPid[a].flatMap({ ProcessSampler.appBundle(of: $0.path) }) {
                    return ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                }
            }
            return nil
        }

        // 1. Tiến trình Claude Code
        func isClaude(_ p: ProcessSampler.Raw) -> Bool {
            guard p.user == me else { return false }
            if p.name == "claude" { return true }
            if p.name == "node" { return args(p.pid).contains { $0.contains("claude-code") || $0.contains("@anthropic-ai/claude") } }
            return false
        }
        let claudePids = Set(procs.filter(isClaude).map(\.pid))

        // 2. Việc dựng video
        var jobs: [(owner: pid_t?, item: TaskItem)] = []
        var handled = Set<pid_t>()
        for p in procs where p.user == me {
            guard let item = videoJob(p, args: args, byPid: byPid, now: now) else { continue }
            let owner = ancestors(p.pid).first { claudePids.contains($0) }
            jobs.append((owner, item))
            handled.insert(p.pid)
        }
        // App dựng phim: chỉ tính khi đang ngốn CPU (đang xuất hoặc xử lý)
        var appGroups: [String: (cpu: Double, pids: [pid_t], name: String)] = [:]
        for p in procs where p.user == me {
            guard let bundle = ProcessSampler.appBundle(of: p.path) else { continue }
            let appName = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            let known = TaskTracker.videoApps[appName] ?? TaskTracker.videoAppPrefixes.first { appName.hasPrefix($0) }.map { _ in appName }
            guard let known else { continue }
            appGroups[bundle, default: (0, [], known)].cpu += p.cpu
            appGroups[bundle, default: (0, [], known)].pids.append(p.pid)
        }
        var appItems: [TaskItem] = []
        for (bundle, g) in appGroups where g.cpu >= 40 {
            let start = g.pids.compactMap(ProcInfo.startTime).min()
            appItems.append(TaskItem(id: "app-" + bundle, kind: .app, title: g.name, subtitle: "Ứng dụng dựng phim",
                                     status: "Đang xử lý hoặc xuất video (CPU \(Int(g.cpu))%). App này không báo % ra ngoài.",
                                     active: true, startedAt: start, iconPath: bundle, symbol: "film", cpu: g.cpu, pids: g.pids))
        }

        // 3. Phiên Claude: nối tiến trình với file nhật ký
        var claimed = Set<String>()
        var sessions: [TaskItem] = []
        var idle: [TaskItem] = []
        for pid in claudePids.sorted() {
            guard let p = byPid[pid] else { continue }
            let a = args(pid)
            let cwd = ProcInfo.cwd(pid)
            let start = ProcInfo.startTime(pid)
            let path = transcriptPath(sessionId: sessionId(from: a), cwd: cwd, processStart: start, claimed: claimed)
            if let path { claimed.insert(path) }
            let info = path.map(session) ?? SessionInfo()
            let children = TaskTracker.mergePipelines(jobs.filter { $0.owner == pid }.map(\.item))
                + heavyDescendants(of: pid, kids: kids, byPid: byPid, skip: handled, args: args)
            let item = sessionItem(id: "cl-" + (path ?? String(pid)), info: info, host: hostApp(pid), cwd: cwd ?? info.cwd,
                                   alive: true, children: children, pids: [pid], cpu: p.cpu, now: now)
            if item.active { sessions.append(item) } else { idle.append(item) }
        }
        // Nhật ký đang được ghi mà không thấy tiến trình (chạy ở nơi khác): vẫn hiện nếu đang làm.
        if scanCount % 3 == 1 {
            for path in recentTranscripts(within: 120) where !claimed.contains(path) {
                let info = session(path)
                guard info.working else { continue }
                let item = sessionItem(id: "cl-" + path, info: info, host: nil, cwd: info.cwd, alive: false,
                                       children: [], pids: [], cpu: 0, now: now)
                if item.active { sessions.append(item) }
            }
        }

        // 4. Agent AI khác
        var agents: [TaskItem] = []
        for p in procs where p.user == me {
            guard let label = TaskTracker.aiAgents[p.name] else { continue }
            let cwd = ProcInfo.cwd(p.pid).map { $0 == "/" ? "" : ($0 as NSString).lastPathComponent } ?? ""
            agents.append(TaskItem(id: "ai-\(p.pid)", kind: .ai, title: label, subtitle: [hostApp(p.pid), cwd].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                                   status: p.cpu > 3 ? "Đang chạy (CPU \(Int(p.cpu))%)" : "Đang mở, chưa làm gì",
                                   active: p.cpu > 3, startedAt: ProcInfo.startTime(p.pid), symbol: "terminal", cpu: p.cpu, pids: [p.pid]))
        }

        // 5. Tiến trình ghim
        var pinned: [TaskItem] = []
        pinsQ.removeAll { pin in !pin.pids.contains { byPid[$0] != nil } && prevActive[pin.id] == nil }
        for pin in pinsQ {
            let alive = pin.pids.filter { byPid[$0] != nil }
            guard !alive.isEmpty else { continue }
            let cpu = alive.compactMap { byPid[$0]?.cpu }.reduce(0, +)
            pinned.append(TaskItem(id: pin.id, kind: .pinned, title: pin.name, subtitle: "Bạn ghim từ tab Tiến trình",
                                   status: "Đang chạy · CPU \(Fmt.cpuPct(cpu))", active: true,
                                   startedAt: alive.compactMap(ProcInfo.startTime).min(), iconPath: pin.iconPath,
                                   symbol: "pin", cpu: cpu, pids: alive))
        }

        // Hai tiến trình claude cùng mở một phiên: chỉ hiện một thẻ.
        func unique(_ items: [TaskItem]) -> [TaskItem] {
            var seen = Set<String>()
            return items.filter { seen.insert($0.id).inserted }
        }
        sessions = unique(sessions)
        idle = unique(idle)
        let orphanJobs = TaskTracker.mergePipelines(jobs.filter { $0.owner == nil }.map(\.item))
        idle += agents.filter { !$0.active }
        let all = sessions + orphanJobs + appItems + agents.filter(\.active) + pinned
        let activeItems = all.filter(\.active) + sessions.flatMap(\.children).filter(\.active)

        // 6. Việc vừa xong: có trong lần quét trước mà nay hết chạy
        var done: [FinishedItem] = []
        let currentIds = Set(activeItems.map(\.id))
        if let last = lastScanQ, now.timeIntervalSince(last) < 40 {
            for (id, prev) in prevActive where !currentIds.contains(id) {
                if !id.hasPrefix("cl-"), let st = prev.start, now.timeIntervalSince(st) < 20 { continue }
                let took = prev.start.map { " · mất " + Fmt.duration(now.timeIntervalSince($0)) } ?? ""
                done.append(FinishedItem(title: prev.title, detail: (id.hasPrefix("cl-") ? "Claude xong lượt" : "Đã xong") + took, endedAt: now))
            }
        }
        prevActive = Dictionary(activeItems.map { ($0.id, (title: $0.title, start: $0.startedAt)) }, uniquingKeysWith: { a, _ in a })
        lastScanQ = now
        // Bỏ lịch sử của việc đã xong để bộ nhớ không phình dần.
        let jobIds = Set(jobs.map(\.item.id))
        history = history.filter { jobIds.contains($0.key) }
        sizeHistory = sizeHistory.filter { jobIds.contains($0.key) }
        pinsQ.removeAll { pin in !pin.pids.contains { byPid[$0] != nil } }
        let pinsOut = pinsQ
        let names = activeItems.map(\.title)

        DispatchQueue.main.async {
            self.tasks = all
            self.waiting = idle
            self.finished = Array((done + self.finished).filter { now.timeIntervalSince($0.endedAt) < 3600 }.prefix(12))
            self.hasActive = !activeItems.isEmpty
            self.activeNames = names
            self.pins = pinsOut
            self.lastScan = now
        }
    }

    // MARK: Phiên Claude

    private func sessionId(from args: [String]) -> String? {
        for (i, a) in args.enumerated() {
            for flag in ["--resume", "--session-id"] {
                if a.hasPrefix(flag + "=") { return String(a.dropFirst(flag.count + 1)) }
                if (a == flag || (flag == "--resume" && a == "-r")), i + 1 < args.count, !args[i + 1].hasPrefix("-") { return args[i + 1] }
            }
        }
        return nil
    }

    /// Claude Code đặt tên thư mục theo đường dẫn, thay mọi ký tự không phải chữ/số Latin bằng "-".
    private func projectDirs(for cwd: String) -> [String] {
        func encode(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? $0 : "-" }))
        }
        let forms = [cwd.precomposedStringWithCanonicalMapping, cwd.decomposedStringWithCanonicalMapping]
        return Array(Set(forms.map { projectsDir + "/" + encode($0) })).filter { FileManager.default.fileExists(atPath: $0) }
    }

    private func transcriptPath(sessionId: String?, cwd: String?, processStart: Date?, claimed: Set<String>) -> String? {
        let fm = FileManager.default
        let dirs = cwd.map(projectDirs) ?? []
        if let sid = sessionId {
            for d in dirs where fm.fileExists(atPath: "\(d)/\(sid).jsonl") { return "\(d)/\(sid).jsonl" }
            for d in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
                let p = "\(projectsDir)/\(d)/\(sid).jsonl"
                if fm.fileExists(atPath: p) { return p }
            }
            return nil
        }
        var best: (String, Date)?
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasSuffix(".jsonl") {
                let p = "\(d)/\(f)"
                guard !claimed.contains(p), let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date else { continue }
                if let s = processStart, m < s.addingTimeInterval(-120) { continue }
                if best == nil || m > best!.1 { best = (p, m) }
            }
        }
        return best?.0
    }

    private func recentTranscripts(within seconds: TimeInterval) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for d in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
            let dir = "\(projectsDir)/\(d)"
            for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".jsonl") {
                let p = "\(dir)/\(f)"
                if let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, -m.timeIntervalSinceNow < seconds { out.append(p) }
            }
        }
        return out
    }

    private func session(_ path: String) -> SessionInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if let c = sessionCache[path], c.mtime == mtime, c.size == size { return c.info }
        let info = TranscriptReader.read(path)
        sessionCache[path] = (mtime, size, info)
        return info
    }

    private func sessionItem(id: String, info: SessionInfo, host: String?, cwd: String?, alive: Bool,
                             children: [TaskItem], pids: [pid_t], cpu: Double, now: Date) -> TaskItem {
        let recent = info.lastActivity.map { now.timeIntervalSince($0) < 600 } ?? false
        let working = info.working && (alive || recent)
        let childActive = children.contains(where: \.active)
        var status: String
        switch info.state {
        case .tool(let d): status = d
        case .thinking: status = "Đang suy nghĩ…"
        case .waitingUser: status = "Đang hỏi bạn, chờ bạn trả lời"
        case .idle: status = "Xong lượt, chờ bạn" + (info.lastActivity.map { " · " + Fmt.ago(now.timeIntervalSince($0)) } ?? "")
        case .unknown: status = "Chưa đọc được nhật ký phiên"
        }
        if info.working && !working { status = "Đã dừng giữa chừng" }
        if !working && childActive { status = "Đang chờ việc nền chạy xong" }
        var sub: [String] = []
        if let m = info.model { sub.append(TranscriptReader.modelName(m) + (info.effort.map { " (\($0))" } ?? "")) }
        if let h = host { sub.append(h) }
        if let c = cwd { sub.append((c as NSString).lastPathComponent) }

        var item = TaskItem(id: id, kind: .claude, title: info.title ?? info.lastPrompt.map { String($0.prefix(60)) } ?? "Phiên Claude",
                            subtitle: sub.joined(separator: " · "), status: status, active: working || childActive,
                            startedAt: working ? info.turnStart : nil, iconPath: claudeIcon, symbol: "sparkle",
                            cpu: cpu, children: children, pids: pids)
        if working, info.todoTotal > 0 {
            let p = Double(info.todoDone) / Double(info.todoTotal)
            var eta: TimeInterval?
            if p > 0, let s = info.turnStart { eta = now.timeIntervalSince(s) * (1 - p) / p }
            item.progress = TaskProgress(fraction: p, eta: eta,
                                         detail: "Việc \(min(info.todoDone + 1, info.todoTotal))/\(info.todoTotal)" + (info.todoCurrent.map { ": " + $0 } ?? ""))
        } else if let slowest = children.compactMap(\.progress.eta).max() {
            item.progress = TaskProgress(fraction: nil, eta: slowest, detail: "Theo việc con chậm nhất")
        } else if working, info.toolCalls > 0 {
            item.progress.detail = "\(info.toolCalls) lần gọi công cụ trong lượt này"
        }
        return item
    }

    private func heavyDescendants(of root: pid_t, kids: [pid_t: [pid_t]], byPid: [pid_t: ProcessSampler.Raw],
                                  skip: Set<pid_t>, args: (pid_t) -> [String]) -> [TaskItem] {
        let shells: Set<String> = ["zsh", "bash", "sh", "sleep", "caffeinate", "tail", "claude", "node", "git"]
        var out: [TaskItem] = []
        var stack = kids[root] ?? []
        var seen = 0
        while let pid = stack.popLast(), seen < 400 {
            seen += 1
            stack += kids[pid] ?? []
            guard !skip.contains(pid), let p = byPid[pid], p.cpu >= 25, !shells.contains(p.name) else { continue }
            let title = TaskTracker.commandLabel(args(pid), name: p.name)
            out.append(TaskItem(id: "ch-\(pid)", kind: .child, title: title, subtitle: title == p.name ? "" : p.name,
                                status: "CPU \(Fmt.cpuPct(p.cpu))", active: true, startedAt: ProcInfo.startTime(pid),
                                iconPath: ProcessSampler.appBundle(of: p.path), symbol: "gearshape.2", cpu: p.cpu, pids: [pid]))
        }
        return out
    }

    /// Tên dễ hiểu cho một lệnh: tên script, "python -m pip", hoặc vài tham số đầu.
    static func commandLabel(_ a: [String], name: String) -> String {
        let rest = Array(a.dropFirst())
        if let script = rest.first(where: { $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".sh") || $0.hasSuffix(".mjs") }) {
            return (script as NSString).lastPathComponent
        }
        if let i = rest.firstIndex(of: "-m"), i + 1 < rest.count { return "\(name) -m \(rest[i + 1])" }
        if rest.first == "-c" { return "\(name) -c (lệnh viết liền)" }
        let words = rest.filter { !$0.hasPrefix("-") }.prefix(2).map { ($0 as NSString).lastPathComponent }
        return words.isEmpty ? name : name + " " + words.joined(separator: " ")
    }

    // MARK: Việc dựng video

    private func parentScriptName(_ ppid: pid_t, args: (pid_t) -> [String], byPid: [pid_t: ProcessSampler.Raw]) -> String? {
        guard byPid[ppid] != nil else { return nil }
        return args(ppid).dropFirst().first { $0.hasSuffix(".py") || $0.hasSuffix(".js") || $0.hasSuffix(".sh") || $0.hasSuffix(".mjs") }
            .map { ($0 as NSString).lastPathComponent }
    }

    /// Tốc độ ghi file đầu ra (byte/giây) trong khoảng 60 giây gần nhất.
    private func writeRate(id: String, size: Int64, now: Date) -> Double? {
        var h = (sizeHistory[id] ?? []).filter { now.timeIntervalSince($0.0) < 60 }
        h.append((now, size))
        sizeHistory[id] = h
        guard let first = h.first, now.timeIntervalSince(first.0) >= 5, size > first.1 else { return nil }
        return Double(size - first.1) / now.timeIntervalSince(first.0)
    }

    /// Pipeline giải mã -> script -> mã hóa: gộp hai ffmpeg cùng cha thành một việc, lấy % của bên giải mã.
    static func mergePipelines(_ items: [TaskItem]) -> [TaskItem] {
        var out = items
        let byParent = Dictionary(grouping: items.indices.filter { items[$0].kind == .video && items[$0].ppid > 1 }) { items[$0].ppid }
        var drop = Set<String>()
        for (_, idx) in byParent {
            guard let dec = idx.first(where: { items[$0].pipeOut }), let enc = idx.first(where: { items[$0].pipeIn }) else { continue }
            var m = out[enc]
            let d = items[dec]
            m.title = m.title.replacingOccurrences(of: "Xuất ", with: "Dựng ")
            let srcName = d.title.replacingOccurrences(of: "Giải mã ", with: "")
            m.subtitle = "giải mã \(srcName) → \(m.parentScript ?? "xử lý") → mã hóa"
            if d.progress.fraction != nil { m.progress = d.progress }
            m.cpu += d.cpu
            m.status = "2 tiến trình ffmpeg · CPU \(Fmt.cpuPct(m.cpu))"
            m.pids += d.pids
            m.startedAt = [m.startedAt, d.startedAt].compactMap { $0 }.min()
            out[enc] = m
            drop.insert(d.id)
        }
        return out.filter { !drop.contains($0.id) }
    }

    private func videoJob(_ p: ProcessSampler.Raw, args: (pid_t) -> [String], byPid: [pid_t: ProcessSampler.Raw], now: Date) -> TaskItem? {
        let name = p.name
        let started = ProcInfo.startTime(p.pid)
        let parentContext = parentScriptName(p.ppid, args: args, byPid: byPid).map { "do \($0) khởi chạy" }

        if name == "ffmpeg" || name.hasPrefix("ffmpeg") {
            let a = args(p.pid)
            let cwd = ProcInfo.cwd(p.pid)
            let parsed = FFmpegProbe.parse(a, cwd: cwd)
            let files = ProcInfo.openFiles(p.pid)
            let id = "ff-\(p.pid)"
            let pipeOut = parsed.output.map(FFmpegProbe.isPipe) ?? false
            let pipeIn = parsed.inputs.contains { FFmpegProbe.isPipe($0.path) }
            let script = parentScriptName(p.ppid, args: args, byPid: byPid)
            let outSize = parsed.output.flatMap { o in files.first { $0.writable && ProcInfo.samePath($0.path, o) } }?.size
            var progress = TaskProgress()
            if let r = FFmpegProbe.progress(inputs: parsed.inputs, outT: parsed.outT, files: files, duration: duration) {
                let frac = min(1, r.done / r.total)
                progress = TaskProgress(fraction: frac, eta: eta(id: id, fraction: frac, started: started, now: now), detail: r.detail)
            } else if let sz = outSize, let rate = writeRate(id: id, size: sz, now: now) {
                progress.detail = "Đã ghi \(Fmt.bytes(Double(sz))) · \(Fmt.bytes(rate))/giây. Nguồn đi qua ống nên không biết tổng, không tính được %."
            } else {
                progress.detail = pipeIn ? "Nguồn đi qua ống nên không biết tổng, không tính được %." : "Không đo được % (nguồn không phải file video thường)"
            }
            func short(_ path: String) -> String {
                let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return dir.isEmpty ? (path as NSString).lastPathComponent : dir + "/" + (path as NSString).lastPathComponent
            }
            let srcFile = parsed.inputs.first { !FFmpegProbe.isPipe($0.path) }.map { ($0.path as NSString).lastPathComponent }
            let title: String
            if pipeOut {
                title = "Giải mã " + (srcFile ?? "video")
            } else {
                title = "Xuất " + (parsed.output.map(short) ?? "video")
            }
            var sub: [String] = []
            if let sc = script { sub.append("do \(sc) khởi chạy") }
            if pipeIn {
                sub.append("nguồn: khung hình từ \(script ?? "tiến trình khác")")
            } else if let s = srcFile {
                sub.append("nguồn: " + s)
            }
            if pipeOut { sub.append("gửi khung hình cho \(script ?? "tiến trình khác")") }
            if let sz = outSize, sz > 0 { sub.append("đã ghi " + Fmt.bytes(Double(sz))) }
            var item = TaskItem(id: id, kind: .video, title: title, subtitle: sub.joined(separator: " · "),
                                status: "ffmpeg · CPU \(Fmt.cpuPct(p.cpu))", active: true, startedAt: started,
                                progress: progress, symbol: "film", cpu: p.cpu, pids: [p.pid])
            item.ppid = p.ppid
            item.pipeIn = pipeIn
            item.pipeOut = pipeOut
            item.parentScript = script
            return item
        }

        var label: String?
        switch name {
        case "HandBrakeCLI": label = "HandBrake"
        case "aerender": label = "After Effects render"
        case "whisper-cli", "whisper": label = "Gỡ băng Whisper"
        case "node", "python", "python3", "Python", "bun":
            let joined = args(p.pid).joined(separator: " ").lowercased()
            if joined.contains("remotion") && (joined.contains("render") || joined.contains("still")) { label = "Render Remotion" }
            else if joined.contains("whisper") { label = "Gỡ băng Whisper" }
            else if joined.contains("demucs") { label = "Tách giọng Demucs" }
        default: break
        }
        guard let label else { return nil }
        return TaskItem(id: "vj-\(p.pid)", kind: .video, title: label, subtitle: parentContext ?? p.name,
                        status: "CPU \(Fmt.cpuPct(p.cpu)) · công cụ này không báo % ra ngoài", active: true,
                        startedAt: started, symbol: "waveform", cpu: p.cpu, pids: [p.pid])
    }

    private func duration(_ path: String, _ size: Int64) -> Double? {
        let key = "\(path)|\(size)"
        if let d = durations[key] { return d > 0 ? d : nil }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["mov", "mp4", "m4v", "m4a", "mp3", "wav", "aac", "mkv", "avi", "mxf", "webm"].contains(ext) else {
            durations[key] = -1
            return nil
        }
        // API đồng bộ (đã cũ nhưng vẫn chạy); đang ở queue nền nên chờ được.
        let d = AVURLAsset(url: URL(fileURLWithPath: path)).duration.seconds
        let result = d.isFinite && d > 0 ? d : -1
        durations[key] = result
        return result > 0 ? result : nil
    }

    /// Thời gian còn lại theo tốc độ trong khoảng 90 giây gần nhất; chưa đủ dữ liệu thì suy từ lúc bắt đầu.
    private func eta(id: String, fraction: Double, started: Date?, now: Date) -> TimeInterval? {
        var h = (history[id] ?? []).filter { now.timeIntervalSince($0.0) < 90 }
        h.append((now, fraction))
        history[id] = h
        if history.count > 200 { history = history.filter { now.timeIntervalSince($0.value.last?.0 ?? .distantPast) < 300 } }
        if let first = h.first, now.timeIntervalSince(first.0) >= 8, fraction > first.1 {
            let rate = (fraction - first.1) / now.timeIntervalSince(first.0)
            return (1 - fraction) / rate
        }
        if let s = started, fraction > 0.02 { return now.timeIntervalSince(s) * (1 - fraction) / fraction }
        return nil
    }
}
