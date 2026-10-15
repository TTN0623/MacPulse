// Theo dõi việc tải lên/tải xuống qua mạng (Drive, iCloud, Dropbox, trình duyệt, rclone…).
// Tốc độ cả máy lấy từ bộ đếm card mạng. Ứng dụng nào đang gửi thì chụp nettop mỗi ~10 giây (chỉ khi đang truyền).
// Trình duyệt không cho biết file hay tổng dung lượng, nên % chỉ có khi người dùng chọn file đang tải.
import Foundation

struct TransferInfo {
    var up: Double              // byte/giây
    var down: Double
    var sent: Double            // byte đã gửi từ lúc app thấy việc này
    var received: Double
    var expected: Double?       // tổng dung lượng người dùng cung cấp
    var uploading: Bool
}

final class NetWatcher {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    // Chỉ đụng tới trên queue của tracker.
    var expected: Double?
    private var prev: (inBytes: UInt64, outBytes: UInt64)?
    private var prevT = Date()
    private var up = 0.0, down = 0.0
    private var streak = 0
    private var start: Date?
    private var lastHot = Date.distantPast
    private var sent = 0.0, received = 0.0
    private var snapshots: [(Date, [pid_t: (name: String, inB: UInt64, outB: UInt64)])] = []
    private var inFlight = false
    private var lastSnapshot = Date.distantPast
    private var culprit: (pid: pid_t, name: String)?
    private var uploading = true

    static let upThreshold = 120_000.0       // 120 KB/s, bỏ qua tiếng ồn của API và đồng bộ nhỏ
    static let downThreshold = 1_500_000.0
    static let hold: TimeInterval = 25       // ngừng 25 giây mới coi là xong (quãng nghỉ giữa các file)

    func update(now: Date, byPid: [pid_t: ProcessSampler.Raw]) -> TaskItem? {
        guard let c = NetProbe.counters() else { return nil }
        defer { prev = c; prevT = now }
        guard let p = prev else { return nil }
        let dt = now.timeIntervalSince(prevT)
        guard dt > 0.5 else { return current(now: now, byPid: byPid) }
        let upNow = c.outBytes >= p.outBytes ? Double(c.outBytes - p.outBytes) / dt : 0
        let downNow = c.inBytes >= p.inBytes ? Double(c.inBytes - p.inBytes) / dt : 0
        up = up * 0.5 + upNow * 0.5
        down = down * 0.5 + downNow * 0.5

        let hotUp = up >= NetWatcher.upThreshold, hotDown = down >= NetWatcher.downThreshold
        let hot = hotUp || hotDown
        // Giữ nguyên chiều đang hiện; chỉ đổi khi chiều kia thật sự vượt ngưỡng (tránh nhảy qua lại).
        if hotUp && !hotDown { uploading = true } else if hotDown && !hotUp { uploading = false }
        if hot {
            lastHot = now
            streak += 1
            requestSnapshot(now: now)   // chụp mốc đầu ngay, để có kết quả sớm
            // Phải nóng 2 lần quét liền mới bắt đầu, tránh một đợt gửi thoáng qua.
            if start == nil && streak >= 2 {
                start = now.addingTimeInterval(-dt)
                sent = 0; received = 0
                snapshots = []; culprit = nil
            }
        } else {
            streak = 0
        }
        if start != nil {
            sent += upNow * dt
            received += downNow * dt
            if now.timeIntervalSince(lastHot) > NetWatcher.hold {
                start = nil; expected = nil; culprit = nil; snapshots = []
                return nil
            }
        }
        return current(now: now, byPid: byPid)
    }

    /// Hết việc: xóa dung lượng người dùng đã nhập.
    func setExpected(_ bytes: Double?) { expected = bytes }

    // MARK: Ứng dụng nào đang gửi

    private func requestSnapshot(now: Date) {
        guard !inFlight, now.timeIntervalSince(lastSnapshot) > 6 else { return }
        inFlight = true
        lastSnapshot = now
        DispatchQueue.global(qos: .utility).async {
            let snap = NetWatcher.nettopSnapshot()
            self.queue.async {
                self.inFlight = false
                guard let snap else { return }
                self.snapshots = Array((self.snapshots + [(Date(), snap)]).suffix(2))
                self.attribute()
            }
        }
    }

    private func attribute() {
        guard snapshots.count == 2 else { return }
        let (t0, a) = snapshots[0], (t1, b) = snapshots[1]
        let dt = max(1, t1.timeIntervalSince(t0))
        var best: (pid: pid_t, name: String, rate: Double)?
        for (pid, now) in b {
            guard let before = a[pid] else { continue }
            let d = uploading ? (now.outB >= before.outB ? now.outB - before.outB : 0) : (now.inB >= before.inB ? now.inB - before.inB : 0)
            let rate = Double(d) / dt
            if rate > (best?.rate ?? 0) { best = (pid, now.name, rate) }
        }
        guard let best, best.rate > 20_000 else { return }
        if let old = culprit, old.name != best.name {
            // Ứng dụng khác bắt đầu gửi: việc cũ coi như xong, đếm lại cho việc mới.
            start = Date(); sent = 0; received = 0; expected = nil
        }
        culprit = (best.pid, best.name)
    }

    /// nettop chạy một lần mất ~5 giây (chờ khởi động) nhưng gần như không tốn CPU.
    static func nettopSnapshot() -> [pid_t: (name: String, inB: UInt64, outB: UInt64)]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-x"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var map: [pid_t: (String, UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix(",") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let i = UInt64(cols[1]), let o = UInt64(cols[2]),
                  let dot = cols[0].lastIndex(of: "."), let pid = pid_t(cols[0][cols[0].index(after: dot)...]) else { continue }
            map[pid] = (String(cols[0][..<dot]), i, o)
        }
        return map.isEmpty ? nil : map
    }

    // MARK: Thẻ hiển thị

    private static let browsers = ["Google Chrome", "Safari", "Dia", "Arc", "Firefox", "Microsoft Edge", "Brave Browser", "Opera", "Cốc Cốc", "CocCoc"]

    private func current(now: Date, byPid: [pid_t: ProcessSampler.Raw]) -> TaskItem? {
        guard let start else { return nil }
        var app: String?
        var iconPath: String?
        var pids: [pid_t] = []
        if let c = culprit, let raw = byPid[c.pid] {
            iconPath = ProcessSampler.appBundle(of: raw.path)
            app = iconPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? raw.name
            pids = [c.pid]
        } else if let c = culprit {
            app = c.name
        }
        let rate = uploading ? up : down
        let total = uploading ? sent : received
        var item = TaskItem(id: "net-" + (culprit?.name ?? "pending") + (uploading ? "-up" : "-down"), kind: .transfer,
                            title: (uploading ? "Đang tải lên" : "Đang tải xuống") + (app.map { ": " + $0 } ?? ""),
                            subtitle: hint(app: app, uploading: uploading), status: "", active: true, startedAt: start,
                            iconPath: iconPath, symbol: uploading ? "arrow.up.circle.fill" : "arrow.down.circle.fill",
                            pids: pids)
        item.status = "\(uploading ? "↑" : "↓") \(Fmt.rate(rate)) · đã \(uploading ? "gửi" : "nhận") \(Fmt.size(total))"
        if now.timeIntervalSince(lastHot) > 6 { item.status += " · đang nghỉ" }
        if app == nil { item.subtitle = "Đang xác định ứng dụng…" }
        if let exp = expected, exp > 0 {
            let frac = min(0.99, total / exp)
            let eta: TimeInterval? = rate > 20_000 ? max(0, exp - total) / rate : nil
            // Bộ đếm card mạng tính cả phần dữ liệu phụ của giao thức (khoảng 3–8%), nên có thể vượt tổng một chút.
            let detail = total >= exp
                ? "Đã \(uploading ? "gửi" : "nhận") đủ \(Fmt.size(exp)), đang chờ hoàn tất"
                : "Đã \(uploading ? "gửi" : "nhận") \(Fmt.size(total)) / \(Fmt.size(exp)) (số đo gồm cả phần phụ của giao thức mạng)"
            item.progress = TaskProgress(fraction: frac, eta: total >= exp ? nil : eta, detail: detail)
        } else {
            item.progress = TaskProgress(fraction: nil, eta: nil, detail: "Chưa biết tổng dung lượng nên chưa tính được %.")
        }
        item.transfer = TransferInfo(up: up, down: down, sent: sent, received: received, expected: expected, uploading: uploading)
        return item
    }

    private func hint(app: String?, uploading: Bool) -> String {
        guard let app else { return "" }
        if NetWatcher.browsers.contains(where: { app.contains($0) }) {
            return "Trình duyệt không cho biết trang hay file nào (có thể là Drive, Gmail, Facebook…)"
        }
        if app.contains("Google Drive") { return "Google Drive đang đồng bộ" }
        if app.contains("Dropbox") { return "Dropbox đang đồng bộ" }
        if app.contains("OneDrive") { return "OneDrive đang đồng bộ" }
        if app == "bird" || app == "cloudd" || app.contains("iCloud") { return "iCloud Drive đang đồng bộ" }
        return uploading ? "Ứng dụng này đang gửi dữ liệu ra mạng" : "Ứng dụng này đang nhận dữ liệu từ mạng"
    }
}
