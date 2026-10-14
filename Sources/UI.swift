// Giao diện bảng bật ra từ thanh menu: Tổng quan · Tiến trình · Quạt.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Tiện ích

/// Ngưỡng nhiệt theo nghiên cứu cho MBP 14" M4 Pro (docs/nhiet-do-m4pro.md).
enum ThermalLevel {
    case good, warm, hot

    var color: Color { self == .good ? .green : self == .warm ? .orange : .red }
    var label: String { self == .good ? "Ổn" : self == .warm ? "Hơi nóng" : "Nóng" }
    var icon: String { self == .good ? "checkmark.circle.fill" : self == .warm ? "exclamationmark.circle.fill" : "flame.fill" }
}

enum ThermalGuide {
    enum Part { case chip, hottest, battery, ssd }

    /// (mức "ổn" tối đa, mức "hơi nóng" tối đa)
    static func limits(_ p: Part) -> (Double, Double) {
        switch p {
        case .chip: return (90, 100)      // CPU/GPU trung bình: mục tiêu 80–90°C khi tải nặng
        case .hottest: return (105, 110)  // điểm nóng nhất: chạm 110°C vài giây thì không sao
        case .battery: return (35, 40)    // Apple: trên 35°C có thể hại dung lượng pin vĩnh viễn
        case .ssd: return (60, 70)
        }
    }

    static func level(_ t: Double?, _ p: Part) -> ThermalLevel? {
        guard let t else { return nil }
        let (ok, warm) = limits(p)
        return t <= ok ? .good : t <= warm ? .warm : .hot
    }

    static func color(_ t: Double?, _ p: Part) -> Color { level(t, p)?.color ?? .secondary }
}

func tempColor(_ t: Double?) -> Color {
    guard let t else { return .secondary }
    return t < 60 ? .green : t < 80 ? .orange : .red
}

func loadColor(_ v: Double) -> Color {
    v < 0.6 ? .accentColor : v < 0.85 ? .orange : .red
}

struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
    }
}

struct TempBadge: View {
    let value: Double?
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "thermometer.medium").foregroundStyle(ThermalGuide.color(value, .chip))
            Text(Fmt.temp(value)).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(ThermalGuide.color(value, .chip).opacity(0.18)))
    }
}

struct MetricHeader: View {
    let title: String
    let value: String
    var temp: Double?
    var showTemp = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if showTemp { TempBadge(value: temp) }
            Spacer()
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var capacity = 60

    var body: some View {
        GeometryReader { g in
            let pts = points(g.size)
            ZStack {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: g.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.03)))
    }

    private func points(_ size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(capacity - 1)
        let offset = capacity - values.count
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i + offset) * step, y: (size.height - 2) * (1 - CGFloat(min(max(v, 0), 1))) + 1)
        }
    }
}

struct Bar: View {
    let fraction: Double
    var color: Color = .accentColor
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(0, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}

// MARK: Tổng quan

struct CoreBars: View {
    let cores: [Double]
    var body: some View {
        let eff = min(SystemInfo.effCores, cores.count)
        HStack(alignment: .bottom, spacing: 10) {
            if eff > 0 { group("E", Array(cores.prefix(eff))) }
            group(eff > 0 ? "P" : "Nhân", Array(cores.dropFirst(eff)))
        }
    }

    private func group(_ label: String, _ values: [Double]) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 2).fill(loadColor(values[i]))
                            .frame(height: max(1, 22 * values[i]))
                    }
                    .frame(width: 9, height: 22)
                }
            }
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

struct OverviewTab: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        let s = m.snapshot
        ScrollView {
            VStack(spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        MetricHeader(title: "CPU", value: Fmt.pct(s.cpuUsage), temp: s.cpuTemp, showTemp: true)
                        Sparkline(values: m.cpuHistory, color: .blue).frame(height: 34)
                        HStack(alignment: .bottom) {
                            CoreBars(cores: s.coreUsage)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Nóng nhất").font(.caption2).foregroundStyle(.secondary)
                                HStack(spacing: 4) {
                                    Dot(color: ThermalGuide.color(s.cpuHottest, .hottest))
                                    Text(Fmt.temp(s.cpuHottest)).font(.callout.weight(.semibold)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        MetricHeader(title: "GPU", value: Fmt.pct(s.gpuUsage), temp: s.gpuTemp, showTemp: true)
                        Sparkline(values: m.gpuHistory, color: .purple).frame(height: 34)
                        Text("Bộ nhớ GPU đang dùng: \(Fmt.bytes(s.gpuMemory))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Card { MemoryCard(mem: s.memory) }
                Card { TempGrid(s: s) }
                Card { ThermalAdviceCard(s: s) }
            }
            .padding(12)
        }
    }
}

struct MemoryCard: View {
    let mem: MemoryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeader(title: "RAM", value: "\(Fmt.bytes(mem.used)) / \(Fmt.bytes(mem.total))")
            GeometryReader { g in
                HStack(spacing: 1) {
                    segment(mem.app, .blue, g.size.width)
                    segment(mem.wired, .orange, g.size.width)
                    segment(mem.compressed, .pink, g.size.width)
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                legend("App", mem.app, .blue)
                legend("Hệ thống", mem.wired, .orange)
                legend("Nén", mem.compressed, .pink)
            }
            HStack {
                Circle().fill(pressureColor).frame(width: 7, height: 7)
                Text("Áp lực bộ nhớ: \(pressureText)")
                Spacer()
                Text("Swap \(Fmt.bytes(mem.swapUsed))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pressureText: String { mem.pressure >= 4 ? "Cao" : mem.pressure >= 2 ? "Trung bình" : "Thấp" }
    private var pressureColor: Color { mem.pressure >= 4 ? .red : mem.pressure >= 2 ? .orange : .green }

    private func segment(_ v: Double, _ c: Color, _ width: CGFloat) -> some View {
        Rectangle().fill(c).frame(width: mem.total > 0 ? max(0, width * v / mem.total) : 0)
    }

    private func legend(_ name: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text("\(name) \(Fmt.bytes(v))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TempGrid: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nhiệt độ & quạt").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                item("CPU nhân hiệu năng", Fmt.temp(s.cpuPerfTemp), ThermalGuide.color(s.cpuPerfTemp, .chip))
                item("CPU nhân tiết kiệm", Fmt.temp(s.cpuEffTemp), ThermalGuide.color(s.cpuEffTemp, .chip))
                item("GPU", Fmt.temp(s.gpuTemp), ThermalGuide.color(s.gpuTemp, .chip))
                item("SSD", Fmt.temp(s.ssdTemp), ThermalGuide.color(s.ssdTemp, .ssd))
                if SystemInfo.hasBattery {
                    item("Pin", Fmt.temp(s.batteryTemp), ThermalGuide.color(s.batteryTemp, .battery))
                }
                item("Công suất máy", s.systemPower.map { "\(Int($0.rounded())) W" } ?? "–", nil)
                ForEach(s.fans) { f in
                    item(f.name(total: s.fans.count) + (f.manual ? " · đang tăng" : ""), Fmt.rpm(f.rpm), nil)
                }
            }
        }
    }

    private func item(_ name: String, _ value: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                if let color { Dot(color: color) }
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            }
        }
    }
}

struct ThermalAdviceCard: View {
    let s: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mức nhiệt khuyến nghị cho máy này").font(.headline)
            row("CPU trung bình", s.cpuTemp, .chip, "≤ 90°C khi tải nặng, 40–60°C khi nghỉ")
            row("GPU trung bình", s.gpuTemp, .chip, "≤ 90°C khi tải nặng")
            row("Điểm nóng nhất", s.cpuHottest, .hottest, "≤ 105°C, chạm 110°C vài giây thì không sao")
            if SystemInfo.hasBattery { row("Pin", s.batteryTemp, .battery, "≤ 35°C, nóng hơn thì pin chai nhanh") }
            row("SSD", s.ssdTemp, .ssd, "< 60°C")
            HStack(alignment: .top, spacing: 4) {
                Text("Máy nóng hại pin trước, chip sau. Muốn mát hơn, bật quạt Thông minh ở tab Quạt.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Xem nghiên cứu") {
                    if let url = Bundle.main.url(forResource: "nhiet-do-m4pro", withExtension: "md") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link).font(.caption2)
            }
        }
    }

    private func row(_ name: String, _ t: Double?, _ part: ThermalGuide.Part, _ target: String) -> some View {
        let lv = ThermalGuide.level(t, part)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: lv?.icon ?? "circle.dashed").foregroundStyle(lv?.color ?? .secondary).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout)
                Text("Mục tiêu " + target).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.temp(t)).font(.callout.weight(.semibold)).monospacedDigit()
                Text(lv?.label ?? "–").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Tiến trình

final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private lazy var generic = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(_ path: String?) -> NSImage {
        guard let path else { return generic }
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}

// SDK macOS 27 biến @State thành macro, Command Line Tools không có plugin cho nó,
// nên trạng thái cục bộ của view giữ trong ObservableObject nhỏ.
final class ViewState<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct ProcessesTab: View {
    @EnvironmentObject var m: Monitor
    @StateObject private var search = ViewState("")
    private var query: String { search.value }

    private var rows: [ProcessRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? m.processes : m.processes.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return Array(list.prefix(80))
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Tìm tiến trình", text: $search.value).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { search.value = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                Picker("", selection: $m.sort) {
                    ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 104)
            }
            HStack {
                Toggle("Gộp theo ứng dụng", isOn: $m.grouped).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("\(m.processCount) tiến trình").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Tên")
                Spacer()
                Text("CPU").frame(width: 56, alignment: .trailing).help("100% = một nhân CPU, máy có \(ProcessInfo.processInfo.processorCount) nhân")
                Text("RAM").frame(width: 70, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 6)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { ProcessRowView(row: $0, grouped: m.grouped) }
                }
            }
            Text("Chuột phải vào một dòng để thoát ứng dụng đó.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
        .onAppear { m.setProcessesVisible(true) }
        .onDisappear { m.setProcessesVisible(false) }
    }
}

struct ProcessRowView: View {
    @EnvironmentObject var tracker: TaskTracker
    let row: ProcessRow
    let grouped: Bool
    @StateObject private var hoverState = ViewState(false)
    private var hover: Bool { hoverState.value }

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: IconCache.shared.icon(row.iconPath)).resizable().frame(width: 18, height: 18)
            Text(row.name).lineLimit(1).truncationMode(.middle)
            if grouped && row.pids.count > 1 {
                Text("\(row.pids.count)").font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            if !row.isMine {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .help("Tiến trình của hệ thống (\(row.user))")
            }
            Spacer(minLength: 4)
            Text(Fmt.cpuPct(row.cpu)).monospacedDigit().frame(width: 56, alignment: .trailing)
                .fontWeight(row.cpu >= 30 ? .semibold : .regular)
                .foregroundStyle(row.cpu >= 80 ? Color.red : Color.primary)
            Text(Fmt.bytes(row.memory)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hoverState.value = $0 }
        .contextMenu {
            if row.isMine {
                Button("Thoát \(row.name)") { ProcessSampler.quit(row, force: false) }
                Button("Buộc thoát") { ProcessSampler.quit(row, force: true) }
                Divider()
            }
            Button("Theo dõi trong Tác vụ") { tracker.pin(row) }
            Button("Sao chép PID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.pids.map(String.init).joined(separator: " "), forType: .string)
            }
        }
    }
}

// MARK: Quạt

struct FansTab: View {
    @EnvironmentObject var m: Monitor
    @EnvironmentObject var fan: FanController

    var body: some View {
        let fans = m.snapshot.fans
        ScrollView {
            VStack(spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        if fans.isEmpty {
                            Label("Máy này không có quạt (như MacBook Air). macOS tự giảm xung khi nóng; MacPulse chỉ theo dõi nhiệt độ.", systemImage: "wind.snow")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(fans) { f in FanRowView(f: f, fanTotal: fans.count, fan: fan) }
                    }
                }
                if !fans.isEmpty {
                    if fan.helperInstalled { controls(fans) } else { installCard }
                }
                if fan.helperInstalled {
                    Label(fan.autoUpdateEnabled ? "Helper quạt tự cập nhật khi app có bản mới (đã bật Luôn cho phép)."
                                                : "Helper quạt cần nhập mật khẩu mỗi lần cập nhật.",
                          systemImage: fan.autoUpdateEnabled ? "checkmark.shield" : "lock")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let err = fan.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
    }

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Cần cấp quyền một lần", systemImage: "lock.shield").font(.headline)
                Text("macOS chỉ cho tiến trình quản trị chỉnh tốc độ quạt. MacPulse sẽ cài một helper nhỏ chạy nền; macOS hỏi mật khẩu máy một lần.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    fan.installHelper()
                } label: {
                    HStack {
                        if fan.busy { ProgressView().controlSize(.small) }
                        Text("Cài quyền điều khiển quạt")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(fan.busy)
                AlwaysAllowToggle(fan: fan)
            }
        }
    }

    private func controls(_ fans: [FanInfo]) -> some View {
        let mode = Binding(get: { fan.mode }, set: { fan.setMode($0) })
        let pct = Binding(get: { fan.percent }, set: { fan.setPercent($0) })
        let sample = fans.first
        return VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: mode) {
                        Text("Tự động").tag(FanMode.auto)
                        Text("Thông minh").tag(FanMode.smart)
                        Text("Thủ công").tag(FanMode.manual)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text(modeNote)
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    switch fan.mode {
                    case .auto:
                        EmptyView()
                    case .smart:
                        SmartFanSection(fan: fan, chipTemp: chipTemp, fans: fans)
                    case .manual:
                        HStack {
                            Text("Tốc độ").font(.headline)
                            Spacer()
                            Text("\(Int(fan.percent))%").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            if let f = sample {
                                Text("≈ \(Fmt.rpm(fan.targetRPM(minRPM: f.minRPM, maxRPM: f.maxRPM)))")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Slider(value: pct, in: 0...100, step: 1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "fan").font(.caption)
                        } maximumValueLabel: {
                            Image(systemName: "fan.fill").font(.callout)
                        }
                        HStack(spacing: 6) {
                            ForEach([0, 25, 50, 75, 100], id: \.self) { p in
                                Button("\(p)%") { fan.setPercent(Double(p)) }.controlSize(.small)
                            }
                        }
                        if let f = sample {
                            Text("0% = \(Fmt.rpm(f.minRPM)) (thấp nhất) · 100% = \(Fmt.rpm(f.maxRPM)) (tối đa)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("Chip từ 110°C thì quạt không chạy dưới 50%.").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Label("Thoát MacPulse thì quạt về Tự động ngay.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Nhiệt điều khiển quạt: nóng hơn giữa trung bình nhân CPU và trung bình GPU.
    private var chipTemp: Double? {
        let s = m.snapshot
        return [s.cpuTemp, s.gpuTemp].compactMap { $0 }.max()
    }

    private var modeNote: String {
        switch fan.mode {
        case .auto: return "macOS tự chỉnh quạt theo nhiệt độ, đúng như cài đặt gốc của máy."
        case .smart: return "macOS vẫn điều khiển quạt. Khi chip vượt ngưỡng bạn đặt mà quạt macOS chạy chậm hơn mức cần, MacPulse tăng quạt; chip nguội lại thì trả quyền cho macOS. Không bao giờ làm quạt yếu hơn mặc định."
        case .manual: return "Giữ cả hai quạt ở tốc độ cố định cho tới khi bạn chuyển chế độ khác."
        }
    }
}

struct SmartFanSection: View {
    @ObservedObject var fan: FanController
    let chipTemp: Double?
    let fans: [FanInfo]

    var body: some View {
        let start = Binding(get: { fan.smartStart }, set: { fan.setSmart(start: $0.rounded(), full: max(fan.smartFull, $0.rounded() + 5)) })
        let full = Binding(get: { fan.smartFull }, set: { fan.setSmart(start: fan.smartStart, full: $0.rounded()) })
        VStack(alignment: .leading, spacing: 10) {
            if fan.helperOutdated {
                Label("Có bản helper mới. Bấm Cập nhật ở dải thông báo phía trên.", systemImage: "arrow.down.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(FanController.presets) { p in
                    let on = p.start == fan.smartStart && p.full == fan.smartFull
                    Button(p.name) { fan.setSmart(start: p.start, full: p.full) }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : nil)
                        .fontWeight(on ? .semibold : .regular)
                        .help(p.note)
                }
                Spacer()
            }
            if let p = FanController.presets.first(where: { $0.start == fan.smartStart && $0.full == fan.smartFull }), !p.note.isEmpty {
                Text(p.note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Bắt đầu tăng quạt từ").font(.callout)
                    Spacer()
                    Text("\(Int(fan.smartStart))°C").font(.callout.weight(.semibold)).monospacedDigit()
                }
                Slider(value: start, in: 60...105, step: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Quạt chạy tối đa khi tới").font(.callout)
                    Spacer()
                    Text("\(Int(fan.smartFull))°C").font(.callout.weight(.semibold)).monospacedDigit()
                }
                Slider(value: full, in: (fan.smartStart + 5)...115, step: 1)
            }
            TempZoneMeter(start: fan.smartStart, full: fan.smartFull, current: chipTemp)
            let safety = fan.activePreset ?? FanController.presets[1]
            Text("Chốt an toàn: điểm nóng nhất từ \(Int(safety.hot))°C thì quạt không dưới \(Int(safety.hotPct))%; macOS báo căng nhiệt thì quạt chạy hết cỡ. Nguội dưới \(Int(fan.smartStart - safety.hyst))°C đủ \(Int(safety.hold)) giây thì trả quyền cho macOS.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Label(status, systemImage: boosting ? "wind" : "checkmark.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var boosting: Bool { fans.contains(where: \.manual) }

    private var status: String {
        guard let t = chipTemp else { return "Đang đọc nhiệt độ…" }
        if boosting {
            let pct = Int((fans.map(\.fraction).reduce(0, +) / Double(max(1, fans.count)) * 100).rounded())
            return "Chip \(Int(t))°C, MacPulse đang tăng quạt (khoảng \(pct)%)."
        }
        if t < fan.smartStart { return "Chip \(Int(t))°C, chưa tới \(Int(fan.smartStart))°C nên macOS đang tự điều khiển quạt." }
        return "Chip \(Int(t))°C đã qua ngưỡng, nhưng quạt macOS đang đủ mạnh nên chưa cần can thiệp."
    }
}

/// Thang nhiệt 40–115°C: vùng macOS tự lo (xám), vùng tăng dần (cam nhạt tới đậm), vùng tối đa (cam đậm),
/// cùng vạch nhiệt hiện tại. Mỗi vùng có nhãn chữ, không chỉ dựa vào màu.
struct TempZoneMeter: View {
    let start: Double
    let full: Double
    let current: Double?
    private let lo = 40.0
    private let hi = 115.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                let xs = x(start, w), xf = x(full, w)
                ZStack(alignment: .topLeading) {
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4)
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: max(0, xs - 1), height: 10).offset(y: 4)
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, xf - xs - 2), height: 10).offset(x: xs + 1, y: 4)
                    UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4)
                        .fill(Color.orange)
                        .frame(width: max(0, w - xf - 1), height: 10).offset(x: xf + 1, y: 4)
                    if let c = current {
                        Capsule().fill(Color.primary)
                            .frame(width: 3, height: 18)
                            .overlay(Capsule().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                            .offset(x: x(c, w) - 1.5)
                            .help("Nhiệt chip lúc này: \(Int(c))°C")
                    }
                    Text("\(Int(start))°").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .position(x: min(max(xs, 12), w - 12), y: 26)
                    Text("\(Int(full))°").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        .position(x: min(max(xf, 12), w - 12), y: 26)
                }
            }
            .frame(height: 32)
            HStack(spacing: 10) {
                swatch(AnyShapeStyle(Color.primary.opacity(0.14)), "macOS tự lo")
                swatch(AnyShapeStyle(LinearGradient(colors: [Color.orange.opacity(0.35), Color.orange.opacity(0.85)], startPoint: .leading, endPoint: .trailing)), "tăng dần")
                swatch(AnyShapeStyle(Color.orange), "tối đa")
                Spacer()
                if let c = current {
                    Text("Lúc này \(Int(c))°C").font(.caption.weight(.semibold)).monospacedDigit()
                }
            }
        }
    }

    private func x(_ t: Double, _ w: CGFloat) -> CGFloat {
        CGFloat((min(max(t, lo), hi) - lo) / (hi - lo)) * w
    }

    private func swatch(_ style: AnyShapeStyle, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(style).frame(width: 12, height: 8)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Quạt quay khi đang chạy (hiệu ứng có từ macOS 15; macOS 14 hiện icon đứng yên).
struct SpinWhen: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.symbolEffect(.rotate, isActive: active) } else { content }
    }
}

struct FanRowView: View {
    let f: FanInfo
    var fanTotal = 2
    @ObservedObject var fan: FanController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "fan").modifier(SpinWhen(active: f.rpm > 0))
                Text(f.name(total: fanTotal)).font(.headline)
                Spacer()
                Text(Fmt.rpm(f.rpm)).font(.callout.weight(.semibold)).monospacedDigit()
            }
            Bar(fraction: f.fraction, color: f.manual ? .orange : .accentColor)
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if f.manual { return (fan.mode == .smart ? "Thông minh đang tăng" : "Thủ công") + " · đích \(Fmt.rpm(f.targetRPM))" }
        if fan.mode == .manual { return "Đang chờ hệ thống nhả quyền điều khiển…" }
        return "Tự động · đang ở khoảng \(Int((f.fraction * 100).rounded()))%"
    }
}

/// Lựa chọn cho helper tự cập nhật về sau mà không hỏi lại mật khẩu.
struct AlwaysAllowToggle: View {
    @ObservedObject var fan: FanController

    var body: some View {
        Toggle(isOn: $fan.allowAutoUpdate) {
            Text("Luôn cho phép: lần sau helper tự cập nhật, không hỏi lại mật khẩu (chỉ nhận bản có chữ ký của MacPulse)")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: Thông báo dưới thanh tab: có bản mới, helper cần cập nhật

struct NoticeBar: View {
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var fan: FanController
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 6) {
            switch updater.state {
            case .available(let v, _):
                bar("arrow.down.circle.fill", "Có bản mới \(v)", .accentColor) {
                    Button("Xem") { if let u = updater.pageURL { NSWorkspace.shared.open(u) } }
                    Button("Cập nhật") { updater.install() }.buttonStyle(.borderedProminent)
                }
            case .downloading:
                bar("arrow.down.circle", "Đang tải bản mới…", .secondary) { ProgressView().controlSize(.small) }
            case .installing:
                bar("checkmark.seal", "Đã kiểm chữ ký, đang cài và mở lại…", .secondary) { ProgressView().controlSize(.small) }
            case .upToDate:
                bar("checkmark.circle", "Bạn đang dùng bản mới nhất (\(updater.currentVersion))", .green) {}
            case .failed(let msg):
                bar("exclamationmark.triangle", msg, .orange) {
                    Button("Trang tải") { if let u = updater.pageURL { NSWorkspace.shared.open(u) } }
                }
            case .idle, .checking:
                EmptyView()
            }
            if fan.helperInstalled && fan.helperOutdated {
                if fan.selfUpdating {
                    bar("checkmark.shield", "Helper quạt đang tự cập nhật (đã bật Luôn cho phép)…", .secondary) {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        bar("fan", "Helper quạt có bản mới, cần nhập mật khẩu", .orange) {
                            Button("Cập nhật") { fan.installHelper() }.disabled(fan.busy)
                        }
                        AlwaysAllowToggle(fan: fan)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .controlSize(.small)
    }

    private func bar<Actions: View>(_ icon: String, _ text: String, _ tint: Color, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actions()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

// MARK: Khung chính

enum Tab: String, CaseIterable {
    case overview = "Tổng quan", processes = "Tiến trình", tasks = "Tác vụ", fans = "Quạt", power = "Hẹn giờ"
}

struct PopoverView: View {
    @EnvironmentObject var m: Monitor
    @EnvironmentObject var fan: FanController
    @EnvironmentObject var updater: Updater
    @ObservedObject var prefs: Prefs
    @AppStorage("tab") private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MacPulse").font(.headline)
                    Text(SystemInfo.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("Thanh menu hiển thị", selection: $prefs.menuBarStyle) {
                        ForEach(MenuBarStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Mở cùng máy", isOn: $prefs.launchAtLogin)
                    Divider()
                    Text("MacPulse \(updater.currentVersion)")
                    Button("Kiểm tra cập nhật") { updater.check() }
                    Toggle("Tự kiểm tra mỗi ngày", isOn: $updater.autoCheck)
                    Divider()
                    Button("Mở Activity Monitor") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                    }
                    if fan.helperInstalled {
                        Button("Gỡ quyền điều khiển quạt") { fan.uninstallHelper() }
                    }
                    Button("Gỡ MacPulse khỏi máy…") { Uninstaller.run(fan: fan) }
                    Divider()
                    Button("Thoát MacPulse") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)

            NoticeBar(tab: $tab)

            Divider().padding(.top, 10)

            Group {
                switch tab {
                case .overview: OverviewTab()
                case .processes: ProcessesTab()
                case .tasks: TasksTab()
                case .fans: FansTab()
                case .power: PowerTab()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 420, height: 660)
    }
}
