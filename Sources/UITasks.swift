// Giao diện tab Tác vụ và tab Hẹn giờ.
import SwiftUI
import AppKit

// MARK: Tác vụ

struct TaskIcon: View {
    let item: TaskItem
    var size: CGFloat = 22

    var body: some View {
        if let path = item.iconPath {
            Image(nsImage: IconCache.shared.icon(path)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.25).fill(item.kind == .video ? Color.purple : Color.gray))
        }
    }
}

struct ProgressBlock: View {
    let p: TaskProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let f = p.fraction {
                HStack(spacing: 8) {
                    Bar(fraction: f, color: .accentColor)
                    Text("\(Int((f * 100).rounded(.down)))%").font(.callout.weight(.semibold)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            HStack(spacing: 6) {
                if let eta = p.eta {
                    Label("còn khoảng \(Fmt.duration(eta)) · xong lúc \(Fmt.time(Date().addingTimeInterval(eta)))", systemImage: "clock")
                        .font(.caption.weight(.medium))
                }
                if p.eta == nil, let d = p.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if p.eta != nil, let d = p.detail { Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
    }
}

struct TaskCard: View {
    let item: TaskItem
    @EnvironmentObject var tracker: TaskTracker
    @StateObject private var expanded = ViewState(false)

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 9) {
                    TaskIcon(item: item, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline).lineLimit(2)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    if let s = item.startedAt {
                        Text(Fmt.duration(Date().timeIntervalSince(s))).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .help("Đã chạy")
                    }
                    if item.kind == .pinned {
                        Button { tracker.unpin(item.id) } label: { Image(systemName: "pin.slash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Bỏ ghim")
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Dot(color: item.active ? .green : .secondary).padding(.top, 4)
                    Text(item.status).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                if item.progress.fraction != nil || item.progress.eta != nil || item.progress.detail != nil {
                    ProgressBlock(p: item.progress)
                }
                if let t = item.transfer {
                    HStack(spacing: 8) {
                        Button(t.expected == nil ? "Chọn file đang tải để biết %…" : "Chọn lại file…") { pickFiles() }
                        if t.expected != nil {
                            Button("Bỏ") { tracker.setExpectedTransfer(nil) }
                        }
                    }
                    .controlSize(.small)
                }
                if !item.children.isEmpty {
                    Divider()
                    let limit = 3
                    let shown = expanded.value ? item.children : Array(item.children.prefix(limit))
                    ForEach(shown) { ChildTaskRow(item: $0) }
                    if item.children.count > limit {
                        Button(expanded.value ? "Thu gọn" : "Hiện thêm \(item.children.count - limit) việc") {
                            expanded.value.toggle()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}

extension TaskCard {
    /// Chọn các file hoặc thư mục đang được tải; cộng dung lượng để tính %.
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "Chọn các file hoặc thư mục bạn đang tải"
        panel.message = "MacPulse cộng dung lượng để tính % (không đọc nội dung file)."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        DispatchQueue.global(qos: .userInitiated).async {
            var total = 0.0
            for u in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
                    while let f = e?.nextObject() as? URL {
                        let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        if v?.isRegularFile == true { total += Double(v?.fileSize ?? 0) }
                    }
                } else {
                    total += Double((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            DispatchQueue.main.async { tracker.setExpectedTransfer(total > 0 ? total : nil) }
        }
    }
}

struct ChildTaskRow: View {
    let item: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                TaskIcon(item: item, size: 18)
                Text(item.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let s = item.startedAt {
                    Text(Fmt.duration(Date().timeIntervalSince(s))).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            ProgressBlock(p: item.progress)
            Text(item.status).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
    }
}

struct TasksTab: View {
    @EnvironmentObject var tracker: TaskTracker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if tracker.lastScan == nil {
                    HStack { ProgressView().controlSize(.small); Text("Đang quét tác vụ…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else if tracker.tasks.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.seal").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Không có tác vụ nào đang chạy").font(.headline)
                        Text("Phiên Claude, việc xuất video (ffmpeg, Remotion, Whisper, CapCut, Final Cut, Premiere…) sẽ hiện ở đây.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                ForEach(tracker.tasks) { TaskCard(item: $0) }

                if !tracker.waiting.isEmpty {
                    Text("Đang chờ bạn").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tracker.waiting) { w in
                                HStack(alignment: .top, spacing: 8) {
                                    TaskIcon(item: w, size: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(w.title).font(.callout).lineLimit(1)
                                        Text([w.subtitle, w.status].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                    }
                }

                if !tracker.finished.isEmpty {
                    HStack {
                        Text("Vừa xong").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Xóa") { tracker.clearFinished() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                    Card {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(tracker.finished) { f in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(f.title).font(.callout).lineLimit(1).truncationMode(.middle)
                                        Text(f.detail).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Fmt.time(f.endedAt)).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Text("Muốn theo dõi tiến trình khác: chuột phải ở tab Tiến trình, chọn \"Theo dõi trong Tác vụ\".")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
            .padding(12)
        }
        .onAppear { tracker.setVisible(true) }
        .onDisappear { tracker.setVisible(false) }
    }
}

// MARK: Hẹn giờ

struct PowerTab: View {
    @EnvironmentObject var power: PowerManager
    @EnvironmentObject var tracker: TaskTracker
    @StateObject private var pickTime = ViewState(Date().addingTimeInterval(3600))

    private var fallbackReady: Bool { FileManager.default.isWritableFile(atPath: PowerManager.powerRequestPath) }

    var body: some View {
        let plan = Binding(get: { power.plan }, set: { power.selectPlan($0) })
        ScrollView {
            VStack(spacing: 10) {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $power.keepAwake) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Giữ máy luôn thức").font(.headline)
                                Text(power.armed ? "Đang bật vì bạn đã hẹn tắt máy." : "Máy không tự ngủ, các tác vụ chạy tiếp khi bạn rời máy.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .disabled(power.armed)
                        Toggle("Cho phép tắt màn hình (máy vẫn chạy)", isOn: $power.allowDisplaySleep)
                            .toggleStyle(.checkbox).font(.callout)
                            .disabled(!power.keepAwake)
                        if SystemInfo.isLaptop {
                            Text("Gập nắp thì máy vẫn ngủ, trừ khi đang cắm sạc và nối màn hình ngoài.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tự tắt máy").font(.headline)
                        Picker("", selection: plan) {
                            Text("Không").tag(OffPlan.none)
                            Text("Hẹn giờ").tag(OffPlan.timer)
                            Text("Khi xong việc").tag(OffPlan.auto)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        switch power.plan {
                        case .none:
                            Text("Máy chỉ giữ thức (nếu bật ở trên), không tự tắt.").font(.caption).foregroundStyle(.secondary)
                        case .timer:
                            timerSection
                        case .auto:
                            autoSection
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kiểu tắt").font(.headline)
                        Picker("", selection: $power.action) {
                            Text("Ngủ").tag(OffAction.sleep)
                            Text("Tắt máy").tag(OffAction.shutdown)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        Text(power.action == .sleep
                             ? "Ngủ: mở nắp hoặc bấm phím là máy chạy tiếp, ứng dụng vẫn mở nguyên."
                             : "Tắt máy: macOS đóng ứng dụng như khi chọn Tắt máy trong menu Apple. App còn file chưa lưu có thể chặn; khi đó sau 3 phút MacPulse cho máy ngủ thay vì ép tắt.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if power.action == .shutdown && !fallbackReady {
                            Text("Để có phương án dự phòng này, bấm Cập nhật helper ở tab Quạt.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                if let err = power.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Trước khi \(power.action.verb) máy sẽ hiện bảng đếm ngược 60 giây để bạn kịp hủy.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
        }
    }

    @ViewBuilder private var timerSection: some View {
        if let d = power.deadline {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Còn").foregroundStyle(.secondary)
                    Text(Fmt.clock(d.timeIntervalSince(power.now))).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                Text("Máy sẽ \(power.action.verb) lúc \(Fmt.time(d))").font(.callout)
                HStack {
                    Button("+15 phút") { power.extend(minutes: 15) }
                    Button("+1 giờ") { power.extend(minutes: 60) }
                    Spacer()
                    Button("Hủy hẹn") { power.cancel() }
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chọn sau bao lâu:").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach([15, 30, 60, 120, 240], id: \.self) { m in
                        Button(m < 60 ? "\(m) phút" : "\(m / 60) giờ") { power.startTimer(minutes: Double(m)) }
                            .controlSize(.small)
                    }
                }
                HStack(spacing: 6) {
                    Text("Hoặc vào lúc").font(.caption).foregroundStyle(.secondary)
                    DatePicker("", selection: $pickTime.value, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).frame(width: 80)
                    Button("Đặt") {
                        var t = pickTime.value
                        let cal = Calendar.current
                        let hm = cal.dateComponents([.hour, .minute], from: t)
                        t = cal.nextDate(after: Date(), matching: hm, matchingPolicy: .nextTime) ?? t
                        power.startTimer(at: t)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder private var autoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Stepper(value: $power.idleMinutes, in: 5...60, step: 5) {
                Text("Hết tác vụ thì chờ \(Int(power.idleMinutes)) phút rồi \(power.action.verb)").font(.callout)
            }
            if tracker.hasActive {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Đang chờ \(tracker.activeNames.count) tác vụ chạy xong", systemImage: "hourglass").font(.callout.weight(.medium))
                    ForEach(Array(tracker.activeNames.prefix(5).enumerated()), id: \.offset) { _, n in
                        Text("• " + n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if tracker.activeNames.count > 5 {
                        Text("và \(tracker.activeNames.count - 5) tác vụ khác").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let end = power.countdownEnd {
                HStack(alignment: .firstTextBaseline) {
                    Text("Hết tác vụ. Máy sẽ \(power.action.verb) sau").foregroundStyle(.secondary)
                    Text(Fmt.clock(end.timeIntervalSince(power.now))).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            Text("Tác vụ gồm mọi thứ ở tab Tác vụ: phiên Claude đang làm, ffmpeg, app dựng phim đang xuất, tiến trình bạn ghim. Có người rê chuột hoặc bấm phím thì đếm lại từ đầu.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
