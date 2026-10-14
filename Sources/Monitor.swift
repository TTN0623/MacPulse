// Lấy mẫu định kỳ. Khi bảng đóng chỉ đọc nhẹ để cập nhật thanh menu; khi mở thì đọc đầy đủ.
import Foundation
import Combine

enum ProcessSort: String, CaseIterable {
    case cpu = "CPU", memory = "RAM"
}

final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var processes: [ProcessRow] = []
    @Published private(set) var processCount = 0

    @Published var sort: ProcessSort = .cpu { didSet { reorder() } }
    @Published var grouped = true {
        didSet {
            let g = grouped
            queue.async { self.groupedOnQueue = g; self.sampleProcesses() }
        }
    }

    var onUpdate: (() -> Void)?

    /// Số liệu mới nhất cho thanh menu. Không @Published để bảng đóng thì SwiftUI không phải vẽ lại.
    private(set) var latest = Snapshot()
    private var cpuHist: [Double] = []
    private var gpuHist: [Double] = []
    private var uiVisible = false          // chỉ đụng tới trên main

    private let reader = SensorReader()
    private let queue = DispatchQueue(label: "macpulse.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var active = false
    private var processesVisible = false
    private var tick = 0
    private var rawProcesses: [ProcessRow] = []
    private var current = Snapshot()      // chỉ đụng tới trên queue
    private var groupedOnQueue = true
    private let historyLength = 60

    init() { schedule() }

    /// Bảng đang mở thì lấy mẫu dày hơn.
    func setActive(_ on: Bool) {
        uiVisible = on
        if on { publish() }
        queue.async {
            self.active = on
            self.schedule()
            if on && self.processesVisible { self.sampleProcesses() }
        }
    }

    func setProcessesVisible(_ on: Bool) {
        queue.async {
            self.processesVisible = on
            if on { self.sampleProcesses() }
        }
    }

    func refreshProcesses() {
        queue.async { self.sampleProcesses() }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: active ? 1.5 : 3, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        tick += 1
        if active || tick == 1 {
            current = reader.snapshot()
        } else {
            // Đóng bảng: chỉ những gì thanh menu và biểu đồ lịch sử cần.
            current.cpuUsage = reader.cpuUsage().total
            current.gpuUsage = reader.gpu().usage
            current.cpuTemp = reader.cpuTemperature()
            if tick % 5 == 0 { current.fans = reader.fans() }
        }
        let s = current
        if active && processesVisible && tick % 2 == 0 { sampleProcesses() }
        DispatchQueue.main.async {
            self.latest = s
            self.cpuHist = Array((self.cpuHist + [s.cpuUsage]).suffix(self.historyLength))
            self.gpuHist = Array((self.gpuHist + [s.gpuUsage]).suffix(self.historyLength))
            if self.uiVisible { self.publish() }
            self.onUpdate?()
        }
    }

    private func publish() {
        snapshot = latest
        cpuHistory = cpuHist
        gpuHistory = gpuHist
    }

    private func sampleProcesses() {
        let rows = ProcessSampler.sample(grouped: groupedOnQueue)
        DispatchQueue.main.async {
            self.rawProcesses = rows
            self.processCount = rows.reduce(0) { $0 + $1.pids.count }
            self.reorder()
        }
    }

    private func reorder() {
        let sorted = rawProcesses.sorted {
            sort == .cpu ? ($0.cpu, $0.memory) > ($1.cpu, $1.memory) : $0.memory > $1.memory
        }
        processes = sorted
    }
}
