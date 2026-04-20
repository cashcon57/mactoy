import Foundation

public enum CRC32 {
    private static let table: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            t[i] = c
        }
        return t
    }()

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<data.count {
                let idx = Int((crc ^ UInt32(p[i])) & 0xFF)
                crc = (crc >> 8) ^ table[idx]
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        return checksum(Data(bytes))
    }
}
