// Phía app của điều khiển quạt: ghi file yêu cầu cho helper (chạy root) đọc.
// App phải ghi lại mỗi vài giây khi ở chế độ thủ công/thông minh; im lặng quá 20 giây thì helper tự trả quạt về auto.
import Foundation

enum FanMode: String {
    case auto, smart, manual
}

/// Mức đặt sẵn cho chế độ Thông minh: bắt đầu tăng quạt từ `start`°C, tối đa khi chạm `full`°C.
struct FanPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let start: Double       // bắt đầu tăng quạt
    let full: Double        // quạt tối đa
    let hot: Double         // chốt an toàn theo điểm nóng nhất
    let hotPct: Double      // quạt tối thiểu khi chạm chốt
    let hyst: Double        // nguội dưới start - hyst ...
    let hold: Double        // ... đủ chừng này giây thì trả quyền cho macOS
    let note: String
}

final class FanController: ObservableObject {
    static let label = "com.tai.macpulse.fanhelper"
    static let requestPath = "/Library/Application Support/MacPulse/fan-request"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let autoUpdateFlagPath = "/Library/Application Support/MacPulse/helper-auto-update"
    static let helperUpdateRequestPath = "/Library/Application Support/MacPulse/helper-update-request"

    @Published private(set) var helperInstalled = false
    @Published private(set) var helperOutdated = false
    @Published private(set) var autoUpdateEnabled = false     // cờ của root: helper được tự cập nhật
    @Published private(set) var selfUpdating = false
    /// Lựa chọn "Luôn cho phép" dùng cho lần cài helper kế tiếp.
    @Published var allowAutoUpdate: Bool = UserDefaults.standard.object(forKey: "helper.allowAutoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(allowAutoUpdate, forKey: "helper.allowAutoUpdate") }
    }
    private var lastSelfUpdate = Date.distantPast
    @Published private(set) var mode: FanMode = .auto
    @Published var percent: Double {
        didSet { UserDefaults.standard.set(percent, forKey: "fanPercent") }
    }
    @Published private(set) var smartStart: Double
    @Published private(set) var smartFull: Double
    @Published private(set) var busy = false
    @Published var lastError: String?

    private var heartbeat: Timer?

    init() {
        let d = UserDefaults.standard
        percent = d.object(forKey: "fanPercent") as? Double ?? 60
        var start = d.object(forKey: "fanSmartStart") as? Double ?? FanController.presets[1].start
        var full = d.object(forKey: "fanSmartFull") as? Double ?? FanController.presets[1].full
        // Ngưỡng tạm của bản đầu (trước khi có nghiên cứu) -> mức đặt sẵn mới cùng tên.
        let legacy: [String: String] = ["90-105": "quiet", "85-100": "balanced", "75-92": "cool"]
        if let id = legacy["\(Int(start))-\(Int(full))"], let p = FanController.presets.first(where: { $0.id == id }) {
            start = p.start
            full = p.full
            d.set(start, forKey: "fanSmartStart")
            d.set(full, forKey: "fanSmartFull")
        }
        smartStart = start
        smartFull = full
        refreshInstalled()
        // Thủ công luôn về Tự động mỗi lần mở app; Thông minh thì giữ lại vì nó chỉ làm quạt mạnh hơn mặc định.
        if helperInstalled {
            // Helper cũ không hiểu "smart" thì coi như auto, quạt vẫn an toàn; nút Cập nhật hiện ở tab Quạt.
            if d.string(forKey: "fanMode") == FanMode.smart.rawValue {
                setMode(.smart)
            } else {
                writeRequest("auto\n")
            }
        }
    }

    func refreshInstalled() {
        let fm = FileManager.default
        helperInstalled = fm.fileExists(atPath: FanController.helperPath) && fm.isWritableFile(atPath: FanController.requestPath)
        autoUpdateEnabled = (try? String(contentsOfFile: FanController.autoUpdateFlagPath, encoding: .utf8))?.hasPrefix("1") ?? false
        // Helper trong app khác bản đã cài (app vừa được cập nhật) thì cập nhật helper.
        if helperInstalled, let res = Bundle.main.resourcePath {
            helperOutdated = !fm.contentsEqual(atPath: FanController.helperPath, andPath: "\(res)/MacPulseFanHelper")
        } else {
            helperOutdated = false
        }
        if helperOutdated && autoUpdateEnabled { requestSelfUpdate() }
        if !helperOutdated { selfUpdating = false }
    }

    /// "Luôn cho phép": báo helper tự lấy bản mới trong app; helper kiểm chữ ký rồi tự thay, không hỏi mật khẩu.
    private func requestSelfUpdate() {
        guard !selfUpdating || Date().timeIntervalSince(lastSelfUpdate) > 60,
              let res = Bundle.main.resourcePath,
              FileManager.default.fileExists(atPath: res + "/MacPulseFanHelper.sig"),
              let h = FileHandle(forWritingAtPath: FanController.helperUpdateRequestPath) else { return }
        try? h.truncate(atOffset: 0)
        h.write((res + "\n").data(using: .utf8)!)
        try? h.close()
        selfUpdating = true
        lastSelfUpdate = Date()
        for delay in [5.0, 12.0, 25.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.selfUpdating else { return }
                self.refreshInstalled()
                // Helper vừa khởi động lại: gửi lại yêu cầu quạt hiện tại.
                if !self.helperOutdated { self.selfUpdating = false; if self.mode != .auto { self.setMode(self.mode) } }
            }
        }
    }

    func setMode(_ m: FanMode) {
        mode = m
        UserDefaults.standard.set(m == .manual ? FanMode.auto.rawValue : m.rawValue, forKey: "fanMode")
        heartbeat?.invalidate()
        heartbeat = nil
        if m == .auto {
            writeRequest("auto\n")
        } else {
            send()
            heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.send() }
        }
    }

    func setPercent(_ p: Double) {
        percent = max(0, min(100, p.rounded()))
        if mode == .manual { send() }
    }

    func setSmart(start: Double, full: Double) {
        smartStart = max(50, min(start, 105))
        smartFull = max(smartStart + 5, min(full, 115))
        UserDefaults.standard.set(smartStart, forKey: "fanSmartStart")
        UserDefaults.standard.set(smartFull, forKey: "fanSmartFull")
        if mode == .smart { send() }
    }

    /// % quạt mà chế độ Thông minh muốn ở nhiệt độ `t` (0 khi chưa tới ngưỡng).
    func smartDemand(at t: Double) -> Double {
        t <= smartStart ? 0 : min(100, (t - smartStart) / (smartFull - smartStart) * 100)
    }

    /// Số vòng/phút ứng với phần trăm hiện tại: 0% = mức thấp nhất, 100% = tối đa.
    func targetRPM(minRPM: Double, maxRPM: Double) -> Double {
        minRPM + (maxRPM - minRPM) * percent / 100
    }

    private func send() {
        let now = Int(Date().timeIntervalSince1970)
        switch mode {
        case .manual: writeRequest("manual \(Int(percent)) \(now)\n")
        case .smart:
            let p = activePreset ?? FanController.presets[1]
            writeRequest("smart \(Int(smartStart)) \(Int(smartFull)) \(Int(p.hot)) \(Int(p.hotPct)) \(Int(p.hyst)) \(Int(p.hold)) \(now)\n")
        case .auto: writeRequest("auto\n")
        }
    }

    private func writeRequest(_ text: String) {
        // Không ghi kiểu atomic: thư mục thuộc root, app chỉ có quyền sửa đúng file này.
        guard let h = FileHandle(forWritingAtPath: FanController.requestPath) else {
            if mode != .auto { lastError = "Chưa ghi được yêu cầu quạt. Hãy cài lại quyền điều khiển quạt." }
            return
        }
        defer { try? h.close() }
        try? h.truncate(atOffset: 0)
        h.write(text.data(using: .utf8)!)
    }

    /// Gọi khi app thoát: trả quạt cho hệ thống ngay, không chờ hết 20 giây.
    func releaseOnQuit() {
        heartbeat?.invalidate()
        if helperInstalled { writeRequest("auto\n") }
    }

    // Theo nghiên cứu cho MBP 14" M4 Pro (docs/nhiet-do-m4pro.md). Nhiệt điều khiển = max(trung bình CPU, trung bình GPU).
    // Chốt an toàn theo điểm nóng nhất nâng lên 112–116°C sau khi đo trên máy: quạt hết cỡ điểm nóng vẫn 110–116°C,
    // nên chốt thấp hơn chỉ làm quạt gào liên tục mà không hạ được nhiệt.
    static let presets: [FanPreset] = [
        FanPreset(id: "quiet", name: "Êm", start: 82, full: 102, hot: 116, hotPct: 70, hyst: 5, hold: 20,
                  note: "Ưu tiên yên tĩnh. Khi tải nặng quạt chỉ mạnh hơn macOS một chút (khoảng 5.900 vòng/phút ở 95°C)."),
        FanPreset(id: "balanced", name: "Cân bằng", start: 72, full: 95, hot: 114, hotPct: 100, hyst: 4, hold: 15,
                  note: "Mặc định. Nhắm CPU trung bình 80–90°C khi tải nặng, đỡ nóng cho pin và bàn phím."),
        FanPreset(id: "cool", name: "Mát", start: 60, full: 88, hot: 112, hotPct: 100, hyst: 3, hold: 10,
                  note: "Mát nhất, quạt ồn hơn. Hợp khi render lâu hoặc để máy chạy qua đêm."),
    ]

    /// Mức đặt sẵn khớp với ngưỡng hiện tại; ngưỡng tự chỉnh thì dùng chốt an toàn của Cân bằng.
    var activePreset: FanPreset? { FanController.presets.first { $0.start == smartStart && $0.full == smartFull } }

    // MARK: Cài / gỡ helper (hiện hộp thoại mật khẩu admin của macOS)

    func installHelper() {
        guard let res = Bundle.main.resourcePath else { return }
        let script = "\(res)/install-helper.sh"
        let helper = "\(res)/MacPulseFanHelper"
        runAsAdmin("/bin/bash \(quoted(script)) \(quoted(helper)) \(quoted(NSUserName())) \(allowAutoUpdate ? "1" : "0")")
    }

    func uninstallHelper() {
        guard let res = Bundle.main.resourcePath else { return }
        mode = .auto
        heartbeat?.invalidate()
        runAsAdmin("/bin/bash \(quoted("\(res)/uninstall-helper.sh"))")
    }

    private func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func runAsAdmin(_ command: String) {
        busy = true
        lastError = nil
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"MacPulse cần quyền quản trị để điều khiển quạt.\" with administrator privileges"
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", source]
            let err = Pipe()
            task.standardError = err
            task.standardOutput = FileHandle.nullDevice
            var message: String?
            do {
                try task.run()
                task.waitUntilExit()
                if task.terminationStatus != 0 {
                    let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    message = text.contains("-128") ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.busy = false
                self.lastError = message
                self.refreshInstalled()
                // Cài xong helper mới: bật lại chế độ Thông minh nếu đó là lựa chọn đã lưu.
                if self.helperInstalled, !self.helperOutdated, self.mode == .auto,
                   UserDefaults.standard.string(forKey: "fanMode") == FanMode.smart.rawValue {
                    self.setMode(.smart)
                }
            }
        }
    }
}
