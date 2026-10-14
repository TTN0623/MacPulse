// Lấy danh sách tiến trình qua /bin/ps (ps có setuid nên thấy cả tiến trình hệ thống).
// Với tiến trình của chính người dùng, RAM lấy theo phys_footprint cho khớp Activity Monitor.
import AppKit
import Darwin

struct ProcessRow: Identifiable {
    let id: String          // pid, hoặc đường dẫn app khi gộp
    let name: String
    let iconPath: String?   // đường dẫn .app để lấy icon
    let user: String
    var cpu: Double         // % (100 = một nhân)
    var memory: Double      // byte
    var pids: [pid_t]
    var isMine: Bool
}

enum ProcessSampler {
    static let me = NSUserName()

    private static func footprint(_ pid: pid_t) -> Double? {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? Double(ru.ri_phys_footprint) : nil
    }

    /// Đường dẫn .app ngoài cùng, để các tiến trình Helper của Chrome… gộp về đúng app.
    static func appBundle(of path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Một dòng của ps, dùng chung cho tab Tiến trình và tab Tác vụ.
    struct Raw {
        let pid: pid_t
        let ppid: pid_t
        let cpu: Double
        let rss: Double     // byte
        let user: String
        let path: String
        var name: String { (path as NSString).lastPathComponent }
    }

    static func raw() -> [Raw] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid=,pcpu=,rss=,user=,comm="]
        task.environment = ["LC_ALL": "C"]   // để ps in "34.5" chứ không phải "34,5"
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Raw] = []
        for line in text.split(separator: "\n") {
            // 5 cột đầu là số và tên user; comm (có thể chứa dấu cách) là phần còn lại.
            let cols = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard cols.count == 6, let pid = pid_t(cols[0]), let ppid = pid_t(cols[1]),
                  let cpu = Double(cols[2]), let rss = Double(cols[3]) else { continue }
            out.append(Raw(pid: pid, ppid: ppid, cpu: cpu, rss: rss * 1024, user: String(cols[4]),
                           path: String(cols[5]).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    static func sample(grouped: Bool) -> [ProcessRow] {
        var rows: [ProcessRow] = []
        for r in raw() {
            let mine = r.user == me
            let mem = (mine ? footprint(r.pid) : nil) ?? r.rss
            rows.append(ProcessRow(id: String(r.pid), name: r.name.isEmpty ? r.path : r.name, iconPath: appBundle(of: r.path),
                                   user: r.user, cpu: r.cpu, memory: mem, pids: [r.pid], isMine: mine))
        }
        guard grouped else { return rows }

        var groups: [String: ProcessRow] = [:]
        var order: [String] = []
        for r in rows {
            let key = r.iconPath ?? r.name
            if var g = groups[key] {
                g.cpu += r.cpu
                g.memory += r.memory
                g.pids += r.pids
                g.isMine = g.isMine && r.isMine
                groups[key] = g
            } else {
                let name = r.iconPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? r.name
                groups[key] = ProcessRow(id: key, name: name, iconPath: r.iconPath, user: r.user,
                                         cpu: r.cpu, memory: r.memory, pids: r.pids, isMine: r.isMine)
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }

    /// Thoát nhẹ nhàng (như Cmd+Q) hoặc buộc thoát. Chỉ áp cho tiến trình của người dùng.
    static func quit(_ row: ProcessRow, force: Bool) {
        let apps = row.pids.compactMap { NSRunningApplication(processIdentifier: $0) }
        if !apps.isEmpty {
            for app in apps { _ = force ? app.forceTerminate() : app.terminate() }
            if !force { return }
        }
        for pid in row.pids { kill(pid, force ? SIGKILL : SIGTERM) }
    }
}
