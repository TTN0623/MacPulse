// Đo lưu lượng mạng rẻ: bộ đếm byte của card mạng (sysctl) cho tốc độ cả máy.
// Đoán ứng dụng nào đang gửi thì chụp nettop một lần mỗi ~10 giây (xem Transfers.swift).
// Không dùng nettop chạy liên tục: tốn trên 100% CPU. Hàng đợi socket TCP cũng không đủ, vì Drive dùng QUIC (UDP).
import Foundation
import Darwin

enum NetProbe {
    /// Tổng byte đã nhận/gửi trên các cổng vật lý (en*), 64 bit. VPN (utun) không cộng thêm để khỏi tính đôi.
    static func counters() -> (inBytes: UInt64, outBytes: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 6, &buf, &size, nil, 0) == 0 else { return nil }
        var rin: UInt64 = 0, rout: UInt64 = 0
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= size {
            let (len, type): (Int, Int32) = buf.withUnsafeBytes {
                let h = $0.load(fromByteOffset: off, as: if_msghdr.self)
                return (Int(h.ifm_msglen), Int32(h.ifm_type))
            }
            guard len > 0 else { break }
            if type == RTM_IFINFO2 {
                let m = buf.withUnsafeBytes { $0.load(fromByteOffset: off, as: if_msghdr2.self) }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(m.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                    rin += m.ifm_data.ifi_ibytes
                    rout += m.ifm_data.ifi_obytes
                }
            }
            off += len
        }
        return (rin, rout)
    }
}
