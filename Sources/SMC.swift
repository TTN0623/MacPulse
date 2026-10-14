// Đọc/ghi SMC (System Management Controller) qua IOKit.
// Đọc không cần root; ghi (tốc độ quạt) phải chạy bằng root.
import Foundation
import IOKit

struct SMCKeyDataVers {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCValue {
    let key: String
    let type: String
    let bytes: [UInt8]

    /// Giải mã theo kiểu dữ liệu SMC. Trả nil nếu kiểu không hỗ trợ.
    var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ", "flag":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        default:
            return nil
        }
    }
}

enum SMCError: Error, CustomStringConvertible {
    case notFound
    case open(kern_return_t)
    case call(kern_return_t, UInt8)
    case sizeMismatch

    var description: String {
        switch self {
        case .notFound: return "Không tìm thấy AppleSMC"
        case .open(let r): return "Không mở được SMC (\(r))"
        case .call(let r, let s): return "Lệnh SMC lỗi (kr=\(r), result=\(s))"
        case .sizeMismatch: return "Sai kích thước dữ liệu"
        }
    }
}

final class SMC {
    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: SMCKeyDataKeyInfo] = [:]
    private let lock = NSLock()

    private static let kernelIndex: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadIndex: UInt8 = 8
    private static let cmdReadKeyInfo: UInt8 = 9

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.notFound }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == kIOReturnSuccess else { throw SMCError.open(r) }
    }

    deinit { IOServiceClose(conn) }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout SMCKeyData) throws -> SMCKeyData {
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let r = IOConnectCallStructMethod(conn, SMC.kernelIndex, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard r == kIOReturnSuccess, output.result == 0 else { throw SMCError.call(r, output.result) }
        return output
    }

    private func keyInfo(_ key: UInt32) throws -> SMCKeyDataKeyInfo {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = key
        input.data8 = SMC.cmdReadKeyInfo
        let info = try call(&input).keyInfo
        infoCache[key] = info
        return info
    }

    func read(_ name: String) -> SMCValue? {
        lock.lock(); defer { lock.unlock() }
        let key = SMC.fourCC(name)
        guard let info = try? keyInfo(key) else { return nil }
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMC.cmdReadBytes
        guard let out = try? call(&input) else { return nil }
        let size = min(Int(info.dataSize), 32)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(size)) }
        return SMCValue(key: name, type: SMC.string(info.dataType), bytes: bytes)
    }

    func number(_ name: String) -> Double? { read(name)?.number }

    /// Ghi thô; số byte phải đúng dataSize của khóa. Cần root.
    func write(_ name: String, bytes: [UInt8]) throws {
        lock.lock(); defer { lock.unlock() }
        let key = SMC.fourCC(name)
        let info = try keyInfo(key)
        guard bytes.count == Int(info.dataSize) else { throw SMCError.sizeMismatch }
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMC.cmdWriteBytes
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        _ = try call(&input)
    }

    /// Ghi một số theo đúng kiểu dữ liệu của khóa.
    func write(_ name: String, number: Double) throws {
        guard let current = read(name) else { throw SMCError.notFound }
        var bytes: [UInt8]
        switch current.type {
        case "flt ":
            let bits = Float(number).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "fpe2":
            let v = UInt16(max(0, number) * 4)
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        case "ui8 ", "flag":
            bytes = [UInt8(max(0, min(255, number)))]
        case "ui16":
            let v = UInt16(max(0, number))
            bytes = [UInt8(v >> 8), UInt8(v & 0xff)]
        default:
            throw SMCError.sizeMismatch
        }
        bytes += Array(repeating: 0, count: max(0, current.bytes.count - bytes.count))
        try write(name, bytes: Array(bytes.prefix(current.bytes.count)))
    }

    /// Liệt kê toàn bộ tên khóa (dùng để dò cảm biến).
    func allKeys() -> [String] {
        guard let count = number("#KEY") else { return [] }
        var keys: [String] = []
        lock.lock(); defer { lock.unlock() }
        for i in 0..<UInt32(count) {
            var input = SMCKeyData()
            input.data8 = SMC.cmdReadIndex
            input.data32 = i
            if let out = try? call(&input) { keys.append(SMC.string(out.key)) }
        }
        return keys
    }
}
