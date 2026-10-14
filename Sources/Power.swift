// Giữ máy thức và hẹn giờ tắt: theo giờ hẹn, hoặc tự tắt khi hết tác vụ.
// Trước khi tắt luôn hiện bảng đếm ngược 60 giây để kịp hủy.
import AppKit
import SwiftUI
import IOKit
import IOKit.pwr_mgt

enum OffPlan: String, CaseIterable {
    case none, timer, auto
}

enum OffAction: String, CaseIterable {
    case sleep, shutdown

    var verb: String { self == .sleep ? "ngủ" : "tắt" }
}

final class PowerManager: ObservableObject {
    static let powerRequestPath = "/Library/Application Support/MacPulse/power-request"

    @Published var keepAwake = false {
        didSet { applyAssertion(); save() }
    }
    @Published var allowDisplaySleep = false {
        didSet { applyAssertion(); save() }
    }
    @Published private(set) var plan: OffPlan = .none
    @Published private(set) var deadline: Date?           // hẹn giờ: lúc sẽ tắt
    @Published private(set) var countdownEnd: Date?       // khi xong việc: lúc sẽ tắt (nil khi còn việc)
    @Published var action: OffAction = .sleep {
        didSet {
            save()
            if action == .shutdown && oldValue != .shutdown { checkShutdownPermission() }
        }
    }
    @Published var idleMinutes: Double = 10 {
        didSet { save() }
    }
    @Published private(set) var now = Date()
    @Published private(set) var warning = false
    @Published var lastError: String?

    /// Đang hẹn tắt máy (hẹn giờ đã đặt, hoặc chế độ tự động).
    var armed: Bool { plan == .auto || (plan == .timer && deadline != nil) }

    /// Lúc sẽ tắt, nếu đã biết.
    var offAt: Date? { plan == .timer ? deadline : (plan == .auto ? countdownEnd : nil) }

    private var assertion: IOPMAssertionID = 0
    private var ticker: Timer?
    private var lastBusy = Date()
    private var panel: NSPanel?
    private weak var tracker: TaskTracker?
    private let defaults = UserDefaults.standard
    private var loading = true

    init(tracker: TaskTracker) {
        self.tracker = tracker
        keepAwake = defaults.bool(forKey: "power.keepAwake")
        allowDisplaySleep = defaults.bool(forKey: "power.allowDisplaySleep")
        action = OffAction(rawValue: defaults.string(forKey: "power.action") ?? "") ?? .sleep
        idleMinutes = defaults.object(forKey: "power.idleMinutes") as? Double ?? 10
        // Khôi phục hẹn giờ khi app mở lại (ví dụ sau khi cập nhật); giờ hẹn đã qua thì bỏ, không tắt đột ngột.
        let savedPlan = OffPlan(rawValue: defaults.string(forKey: "power.plan") ?? "") ?? .none
        let savedDeadline = defaults.object(forKey: "power.deadline") as? Date
        loading = false
        switch savedPlan {
        case .timer:
            if let d = savedDeadline, d.timeIntervalSinceNow > 90 { startTimer(at: d) } else { selectPlan(.timer) }
        case .auto: selectPlan(.auto)
        case .none: break
        }
        applyAssertion()
        clearPowerRequest()
    }

    // MARK: Điều khiển

    func selectPlan(_ p: OffPlan) {
        plan = p
        deadline = nil
        countdownEnd = nil
        hideWarning()
        if p == .auto {
            lastBusy = Date()
            keepAwake = true
        }
        tracker?.setBackground(p == .auto)
        refreshTicker()
        save()
    }

    func startTimer(minutes: Double) {
        startTimer(at: Date().addingTimeInterval(minutes * 60))
    }

    func startTimer(at date: Date) {
        plan = .timer
        deadline = date
        keepAwake = true
        hideWarning()
        tracker?.setBackground(false)
        refreshTicker()
        save()
    }

    func extend(minutes: Double) {
        guard let d = deadline else { return }
        startTimer(at: max(d, Date()).addingTimeInterval(minutes * 60))
    }

    /// Hủy hẹn tắt máy, vẫn giữ máy thức.
    func cancel() {
        selectPlan(plan == .auto ? .none : plan)
        if plan == .timer { deadline = nil }
    }

    // MARK: Đếm ngược

    private func refreshTicker() {
        ticker?.invalidate()
        ticker = nil
        guard armed else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        tick()
    }

    private func tick() {
        now = Date()
        var end: Date?
        switch plan {
        case .timer:
            end = deadline
        case .auto:
            let busy = tracker?.hasActive ?? true
            if busy { lastBusy = now }
            countdownEnd = PowerManager.autoOffAt(now: now, busy: busy, lastBusy: lastBusy,
                                                  userIdle: userIdleSeconds(), waitMinutes: idleMinutes)
            end = countdownEnd
        case .none:
            return
        }
        guard let end else { hideWarning(); return }
        let left = end.timeIntervalSince(now)
        if left <= 0 {
            perform()
        } else if left <= 60 {
            showWarning()
        } else {
            hideWarning()
        }
    }

    /// Lúc sẽ tắt ở chế độ "Khi xong việc": nil khi còn việc. Đếm lại từ đầu khi còn việc chạy,
    /// hoặc khi có người đụng chuột/bàn phím (userIdle = số giây từ lần cuối có thao tác).
    static func autoOffAt(now: Date, busy: Bool, lastBusy: Date, userIdle: TimeInterval, waitMinutes: Double) -> Date? {
        guard !busy else { return nil }
        let quietSince = max(lastBusy, now.addingTimeInterval(-userIdle))
        return quietSince.addingTimeInterval(waitMinutes * 60)
    }

    /// Số giây từ lần cuối có người bấm phím hoặc rê chuột.
    func userIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        return (v?.doubleValue ?? 0) / 1_000_000_000
    }

    // MARK: Tắt máy

    func performNow() { perform() }

    private func perform() {
        let act = action
        hideWarning()
        plan = .none
        deadline = nil
        countdownEnd = nil
        tracker?.setBackground(false)
        ticker?.invalidate()
        ticker = nil
        keepAwake = false     // nhả khóa thức trước khi tắt
        save()
        // Biến môi trường MACPULSE_DRYRUN: chỉ ghi log, không ngủ/tắt thật (để thử bảng đếm ngược).
        if ProcessInfo.processInfo.environment["MACPULSE_DRYRUN"] != nil {
            NSLog("MacPulse DRYRUN: lẽ ra đã %@ máy", act.verb)
            return
        }
        switch act {
        case .sleep:
            run("/usr/bin/pmset", ["sleepnow"])
        case .shutdown:
            // Ghi yêu cầu cho helper: nếu sau 3 phút máy vẫn chưa tắt (có app chặn) thì helper cho máy ngủ.
            writePowerRequest("shutdown \(Int(Date().timeIntervalSince1970))\n")
            runAppleScript("tell application \"System Events\" to shut down")
        }
    }

    private func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        try? p.run()
    }

    private func runAppleScript(_ source: String, completion: ((String?) -> Void)? = nil) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var message: String?
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async { completion?(message) }
        }
    }

    /// Tắt máy cần quyền điều khiển System Events. Hỏi ngay lúc chọn, khi bạn còn ngồi trước máy.
    private func checkShutdownPermission() {
        runAppleScript("tell application \"System Events\" to count processes") { [weak self] err in
            guard let err else { self?.lastError = nil; return }
            self?.lastError = err.contains("-1743") || err.contains("Not authorized")
                ? "Cần cho phép MacPulse điều khiển System Events: Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Tự động hóa."
                : "Chưa kiểm tra được quyền tắt máy: \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    private func writePowerRequest(_ text: String) {
        guard let h = FileHandle(forWritingAtPath: PowerManager.powerRequestPath) else { return }
        defer { try? h.close() }
        try? h.truncate(atOffset: 0)
        h.write(text.data(using: .utf8)!)
    }

    private func clearPowerRequest() { writePowerRequest("none\n") }

    // MARK: Khóa thức

    private func applyAssertion() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        guard keepAwake else { return }
        let type = allowDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "MacPulse keep-awake" as CFString, &assertion)
    }

    private func save() {
        guard !loading else { return }
        defaults.set(keepAwake, forKey: "power.keepAwake")
        defaults.set(allowDisplaySleep, forKey: "power.allowDisplaySleep")
        defaults.set(action.rawValue, forKey: "power.action")
        defaults.set(idleMinutes, forKey: "power.idleMinutes")
        defaults.set(plan.rawValue, forKey: "power.plan")
        defaults.set(deadline, forKey: "power.deadline")
    }

    // MARK: Bảng cảnh báo 60 giây

    private func showWarning() {
        warning = true
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 170),
                        styleMask: [.titled, .nonactivatingPanel, .hudWindow, .utilityWindow], backing: .buffered, defer: false)
        p.title = "MacPulse"
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: OffWarningView(power: self))
        p.center()
        p.orderFrontRegardless()
        panel = p
        NSSound(named: "Glass")?.play()
    }

    private func hideWarning() {
        warning = false
        panel?.orderOut(nil)
        panel = nil
    }
}

struct OffWarningView: View {
    @ObservedObject var power: PowerManager

    var body: some View {
        let left = power.offAt.map { $0.timeIntervalSince(power.now) } ?? 0
        VStack(spacing: 12) {
            Image(systemName: power.action == .sleep ? "moon.zzz.fill" : "power").font(.system(size: 28))
            Text("Máy sẽ \(power.action.verb) sau \(Int(max(0, left).rounded(.up))) giây")
                .font(.headline).monospacedDigit()
            Text(power.plan == .auto ? "Đã hết tác vụ. Rê chuột hoặc bấm phím để đếm lại từ đầu." : "Đến giờ đã hẹn.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Hủy hẹn giờ") { power.cancel() }.keyboardShortcut(.cancelAction)
                Button(power.action == .sleep ? "Ngủ ngay" : "Tắt ngay") { power.performNow() }
            }
        }
        .padding(18)
        .frame(width: 360, height: 170)
    }
}
