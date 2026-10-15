// MacPulse: icon trên thanh menu hiện nhiệt độ, tải máy, tiến trình và điều khiển quạt.
import AppKit
import SwiftUI
import Combine

enum MenuBarStyle: String, CaseIterable {
    case temp, cpu, icon

    var title: String {
        switch self {
        case .temp: return "Nhiệt độ CPU"
        case .cpu: return "% CPU"
        case .icon: return "Chỉ icon"
        }
    }
}

final class Prefs: ObservableObject {
    static let agentLabel = "com.tai.macpulse"
    static var agentPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(agentLabel).plist" }

    @Published var menuBarStyle: MenuBarStyle {
        didSet { UserDefaults.standard.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    init() {
        menuBarStyle = MenuBarStyle(rawValue: UserDefaults.standard.string(forKey: "menuBarStyle") ?? "") ?? .temp
        launchAtLogin = FileManager.default.fileExists(atPath: Prefs.agentPath)
        // Lần đầu mở: bật mở cùng máy để icon luôn có trên thanh menu.
        if !UserDefaults.standard.bool(forKey: "didFirstRun") {
            UserDefaults.standard.set(true, forKey: "didFirstRun")
            launchAtLogin = true
        }
        // App bị dời chỗ thì cập nhật lại đường dẫn khởi động.
        if launchAtLogin { applyLaunchAtLogin() }
    }

    private func applyLaunchAtLogin() {
        let path = Prefs.agentPath
        guard launchAtLogin, let exe = Bundle.main.executablePath else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let plist: [String: Any] = [
            "Label": Prefs.agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        (plist as NSDictionary).write(toFile: path, atomically: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = Monitor()
    let fan = FanController()
    let prefs = Prefs()
    let tracker = TaskTracker()
    let updater = Updater()
    lazy var power = PowerManager(tracker: tracker)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var currentSymbol = ""
    private var bag = Set<AnyCancellable>()
    private var termSource: DispatchSourceSignal?
    private var qaWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.toolTip = "MacPulse"

        let root = PopoverView(prefs: prefs).environmentObject(monitor).environmentObject(fan)
            .environmentObject(tracker).environmentObject(power).environmentObject(updater)
        // Kích thước cố định: nếu để SwiftUI tự báo, mỗi tab có nội dung khác nhau sẽ làm popover co giãn khi chuyển tab.
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 420, height: 660)
        popover.behavior = .transient
        popover.delegate = self

        monitor.onUpdate = { [weak self] in self?.updateStatusItem() }
        // @Published phát trước khi giá trị đổi, nên đợi một nhịp rồi mới vẽ lại.
        prefs.$menuBarStyle.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }.store(in: &bag)
        fan.$mode.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }.store(in: &bag)
        power.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }.store(in: &bag)
        updateStatusItem()

        // Bị tắt bằng kill/pkill: thoát qua NSApp để kịp trả quạt về auto.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        // Chạy thẳng từ file .dmg: đề nghị chuyển vào thư mục Ứng dụng.
        DispatchQueue.main.async { AppLocation.offerMoveIfNeeded() }

        // --qa-window <tab> [dark]: vẽ bảng vào cửa sổ riêng nằm sau mọi cửa sổ để chụp kiểm tra
        // (screencapture -l <id>), không che hay chụp lẫn màn hình người dùng.
        if let i = CommandLine.arguments.firstIndex(of: "--qa-window") {
            let args = CommandLine.arguments
            if i + 1 < args.count { UserDefaults.standard.set(args[i + 1], forKey: "tab") }
            let qaRoot = PopoverView(prefs: prefs).environmentObject(monitor).environmentObject(fan)
                .environmentObject(tracker).environmentObject(power).environmentObject(updater)
            let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 420, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)   // nằm sau mọi cửa sổ
            w.contentViewController = NSHostingController(rootView: qaRoot)
            if args.contains("dark") { w.appearance = NSAppearance(named: .darkAqua) } else { w.appearance = NSAppearance(named: .aqua) }
            w.backgroundColor = .windowBackgroundColor
            w.title = "MacPulse QA"
            w.orderFrontRegardless()
            qaWindow = w
            monitor.setActive(true)
            if UserDefaults.standard.string(forKey: "tab") == Tab.tasks.rawValue { tracker.setVisible(true) }
        }

        // --qa-cycle: mở bảng rồi tự đổi tab bằng code mỗi 1,2 giây (không cần chuột), để quan sát co giãn.
        if CommandLine.arguments.contains("--qa-cycle") {
            let names = Tab.allCases.map(\.rawValue)
            var i = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover() }
            Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
                i = (i + 1) % names.count
                UserDefaults.standard.set(names[i], forKey: "tab")
            }
        }

        // Chạy kèm --show thì tự mở bảng (dùng khi kiểm tra giao diện).
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.togglePopover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        fan.releaseOnQuit()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            fan.refreshInstalled()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        monitor.setActive(true)
        if UserDefaults.standard.string(forKey: "tab") == Tab.tasks.rawValue { tracker.setVisible(true) }
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setActive(false)
        tracker.setVisible(false)   // onDisappear của SwiftUI không chạy khi popover đóng
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let s = monitor.latest
        // Ưu tiên: đang hẹn tắt máy > đang giữ thức > quạt thủ công > bình thường
        let symbol = power.armed ? (power.action == .sleep ? "moon.zzz.fill" : "power")
            : power.keepAwake ? "cup.and.saucer.fill"
            : fan.mode == .manual ? "fan.fill" : "cpu"
        if symbol != currentSymbol {
            currentSymbol = symbol
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacPulse")?.withSymbolConfiguration(config)
            img?.isTemplate = true
            button.image = img
        }
        var text = ""
        switch prefs.menuBarStyle {
        case .temp: text = s.cpuTemp.map { "\(Int($0.rounded()))°" } ?? ""
        case .cpu: text = "\(Int((s.cpuUsage * 100).rounded()))%"
        case .icon: text = ""
        }
        // Còn bao lâu nữa thì tắt máy, kiểu "42p" hoặc "1g30"
        if let at = power.offAt {
            let m = max(0, Int((at.timeIntervalSinceNow / 60).rounded(.up)))
            let left = m >= 60 ? "\(m / 60)g\(String(format: "%02d", m % 60))" : "\(m)p"
            text = text.isEmpty ? left : text + " · " + left
        }
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.attributedTitle = NSAttributedString(
            string: text.isEmpty ? "" : " " + text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
