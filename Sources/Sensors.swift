// Đọc CPU, RAM, GPU, nhiệt độ và quạt. Không cần quyền root.
import Foundation
import IOKit
import Darwin

struct FanInfo: Identifiable {
    let id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var manual: Bool

    /// "Quạt" nếu máy chỉ có một quạt, "Quạt 1", "Quạt 2" nếu nhiều.
    func name(total: Int) -> String { total <= 1 ? "Quạt" : "Quạt \(id + 1)" }

    /// Cùng thang với thanh kéo: 0 = mức thấp nhất, 1 = tối đa.
    var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM)))
    }
}

struct MemoryInfo {
    var total: Double = 0      // byte
    var used: Double = 0       // app + wired + compressed (giống Activity Monitor)
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var pressure: Int = 1      // 1 bình thường, 2 cảnh báo, 4 nguy hiểm

    var fraction: Double { total > 0 ? used / total : 0 }
}

struct Snapshot {
    var cpuUsage: Double = 0           // 0...1
    var coreUsage: [Double] = []
    var gpuUsage: Double = 0
    var gpuMemory: Double = 0          // byte đang dùng
    var memory = MemoryInfo()
    var cpuTemp: Double?               // trung bình các nhân
    var cpuHottest: Double?
    var cpuPerfTemp: Double?
    var cpuEffTemp: Double?
    var gpuTemp: Double?
    var batteryTemp: Double?
    var ssdTemp: Double?
    var systemPower: Double?           // W
    var fans: [FanInfo] = []
}

final class SensorReader {
    let smc: SMC?
    private var perfKeys: [String] = []
    private var effKeys: [String] = []
    private var gpuKeys: [String] = []
    private var quickKeys: [String] = []   // nhóm nhỏ đại diện cho thanh menu
    private var batteryKeys: [String] = []
    private var ssdKeys: [String] = []
    private var fanCount = 0
    private var prevTicks: [[UInt32]] = []
    private var gpuService: io_service_t = 0
    private let pageSize = Double(vm_kernel_page_size)
    private let totalMemory: Double

    init() {
        smc = try? SMC()
        var mem: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        totalMemory = Double(mem)
        discoverKeys()
        gpuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        _ = cpuUsage() // mồi lần đầu để lần sau tính được chênh lệch
    }

    deinit { if gpuService != 0 { IOObjectRelease(gpuService) } }

    /// Dò khóa nhiệt độ theo tiền tố, vì mỗi đời chip đặt tên khác nhau.
    private func discoverKeys() {
        guard let smc else { return }
        let keys = smc.allKeys().filter { $0.hasPrefix("T") }
        // Lấy đủ mọi khóa kiểu số thực; số vô lý (nhân đang nghỉ có lúc đọc ra 0, âm, vài độ) bị lọc ở từng lần đọc,
        // vì lọc một lần lúc khởi động sẽ loại oan cảm biến của nhân đang nghỉ đúng lúc đó.
        func pick(_ prefix: String) -> [String] {
            keys.filter { $0.hasPrefix(prefix) && smc.read($0)?.type == "flt " }
        }
        perfKeys = pick("Tp")
        effKeys = pick("Te")
        gpuKeys = pick("Tg")
        batteryKeys = ["TB0T", "TB1T", "TB2T"].filter { smc.read($0) != nil }
        ssdKeys = ["TH0a", "TH0b", "TH0x"].filter { smc.read($0) != nil }
        fanCount = Int(smc.number("FNum") ?? 0)
        let all = perfKeys + effKeys
        let step = max(1, all.count / 16)
        quickKeys = stride(from: 0, to: all.count, by: step).map { all[$0] }
    }

    private func temps(_ keys: [String]) -> [Double] {
        guard let smc else { return [] }
        return keys.compactMap { smc.number($0) }.filter { $0 > 10 && $0 < 125 }
    }

    private func average(_ v: [Double]) -> Double? {
        v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    func cpuUsage() -> (total: Double, cores: [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            let base = i * Int(CPU_STATE_MAX)
            ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return (0, Array(repeating: 0, count: ticks.count)) }
        var busyAll = 0.0, totalAll = 0.0
        var cores: [Double] = []
        for (now, before) in zip(ticks, prevTicks) {
            let d = zip(now, before).map { Double($0 &- $1) }
            let idle = d[Int(CPU_STATE_IDLE)]
            let total = d.reduce(0, +)
            let busy = total - idle
            busyAll += busy; totalAll += total
            cores.append(total > 0 ? busy / total : 0)
        }
        return (totalAll > 0 ? busyAll / totalAll : 0, cores)
    }

    func memory() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var m = MemoryInfo()
        m.total = totalMemory
        guard r == KERN_SUCCESS else { return m }
        m.app = Double(Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * pageSize
        m.wired = Double(stats.wire_count) * pageSize
        m.compressed = Double(stats.compressor_page_count) * pageSize
        m.cached = Double(stats.external_page_count + stats.purgeable_count) * pageSize
        m.used = m.app + m.wired + m.compressed

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = Double(swap.xsu_used) }
        var level: Int32 = 1
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { m.pressure = Int(level) }
        return m
    }

    func gpu() -> (usage: Double, memory: Double) {
        guard gpuService != 0,
              let perf = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return (0, 0) }
        let usage = (perf["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0
        let mem = (perf["In use system memory"] as? NSNumber)?.doubleValue ?? 0
        return (usage / 100, mem)
    }

    func fans() -> [FanInfo] {
        guard let smc else { return [] }
        return (0..<fanCount).map { i in
            FanInfo(id: i,
                    rpm: smc.number("F\(i)Ac") ?? 0,
                    minRPM: smc.number("F\(i)Mn") ?? 0,
                    maxRPM: smc.number("F\(i)Mx") ?? 0,
                    targetRPM: smc.number("F\(i)Tg") ?? 0,
                    manual: (smc.number("F\(i)Md") ?? 0) == 1)
        }
    }

    /// Đọc nhanh cho thanh menu: nhiệt CPU từ khoảng 16 cảm biến rải đều.
    func cpuTemperature() -> Double? {
        average(temps(quickKeys))
    }

    func snapshot() -> Snapshot {
        var s = Snapshot()
        let cpu = cpuUsage()
        s.cpuUsage = cpu.total
        s.coreUsage = cpu.cores
        let g = gpu()
        s.gpuUsage = g.usage
        s.gpuMemory = g.memory
        s.memory = memory()
        let p = temps(perfKeys), e = temps(effKeys)
        s.cpuPerfTemp = average(p)
        s.cpuEffTemp = average(e)
        s.cpuTemp = average(p + e)
        s.cpuHottest = (p + e).max()
        s.gpuTemp = average(temps(gpuKeys))
        s.batteryTemp = average(temps(batteryKeys))
        s.ssdTemp = average(temps(ssdKeys))
        if let w = smc?.number("PSTR"), w > 0, w < 500 { s.systemPower = w }
        s.fans = fans()
        return s
    }
}
