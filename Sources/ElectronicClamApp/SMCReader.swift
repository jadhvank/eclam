import Foundation
import IOKit
import OSLog

/// Minimal SMC reader for thermal/fan sensors. Apple Silicon only (Intel uses
/// completely different keys); all reads return `nil` gracefully on unsupported
/// hardware so callers can render "—".
///
/// We open `AppleSMC` once per process; `IOServiceOpen` takes a connect type
/// of `0` which gives us a regular user-space client. No entitlements required
/// for reads — only `SMCWriteKey` would; we never call it.
///
/// This wraps just enough surface for ADR-0004 Phase 2 visualization:
/// a few key reads + Float32 / 16-bit fixed point decoding. Real-world Apple
/// Silicon SMC reports differ slightly across families (M1/M2/M3+); we try
/// several common keys and use whichever returns first.
enum SMCReader {
    private static let log = Logger(subsystem: "com.jadhvank.eclam", category: "smc")
    private static let conn: io_connect_t? = {
        var iter: io_iterator_t = 0
        let match = IOServiceMatching("AppleSMC")
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter)
        guard kr == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iter) }
        let service = IOIteratorNext(iter)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr2 = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr2 == kIOReturnSuccess else {
            log.warning("IOServiceOpen(AppleSMC) failed: \(kr2, privacy: .public)")
            return nil
        }
        // `SMCKeyData` MUST stride to exactly 80 bytes to match the kernel's
        // `SMCKeyData_t` ABI; a mismatch makes IOConnectCallStructMethod reject
        // every call with kIOReturnBadArgument and all reads silently return nil.
        if MemoryLayout<SMCKeyData>.stride != 80 {
            log.error("SMCKeyData stride=\(MemoryLayout<SMCKeyData>.stride, privacy: .public) (expected 80); SMC reads will fail")
        }
        return c
    }()

    /// Public API: try the first key that returns a sensible (1..150°C) value.
    /// Returned values are °C.
    static func cpuTemperatureCelsius() -> Double? {
        // M-series PMU/SoC keys, ordered by frequency of being populated.
        let keys = ["Tp09", "Tp0a", "Tp0b", "Tp0c", "Tp01", "Tp05", "TC0P", "TC0E", "TC0F"]
        return firstSane(keys: keys, kind: .floatTemp)
    }

    static func gpuTemperatureCelsius() -> Double? {
        let keys = ["Tg0f", "Tg05", "Tg0d", "Tg0H", "TG0P"]
        return firstSane(keys: keys, kind: .floatTemp)
    }

    /// Fan 0 actual RPM. Returns nil on fan-less Macs (Air, etc.).
    static func fan0RPM() -> Int? {
        let keys = ["F0Ac"]
        guard let v = firstSane(keys: keys, kind: .fpe2Rpm) else { return nil }
        return Int(v.rounded())
    }

    // MARK: - Internals

    private enum DecodeKind { case floatTemp, fpe2Rpm }

    private static func firstSane(keys: [String], kind: DecodeKind) -> Double? {
        guard conn != nil else { return nil }
        for key in keys {
            if let v = read(key: key, kind: kind),
               (kind == .floatTemp ? (v > 1 && v < 150) : (v >= 0 && v < 20000)) {
                return v
            }
        }
        return nil
    }

    private static func read(key: String, kind: DecodeKind) -> Double? {
        guard let conn = conn else { return nil }
        guard let info = readKeyInfo(conn: conn, key: key) else { return nil }
        // Now read the actual bytes.
        var input = SMCKeyData(); var output = SMCKeyData()
        input.key = makeFourCC(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5  // SMC_CMD_READ_BYTES
        let inSize = MemoryLayout<SMCKeyData>.stride
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }
        return decode(bytes: output.bytes, size: Int(info.dataSize), kind: kind, type: info.dataType)
    }

    private static func readKeyInfo(conn: io_connect_t, key: String) -> SMCKeyInfo? {
        var input = SMCKeyData(); var output = SMCKeyData()
        input.key = makeFourCC(key)
        input.data8 = 9  // SMC_CMD_READ_KEYINFO
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }
        return output.keyInfo
    }

    private static func decode(bytes: SMCKeyData.Bytes, size: Int, kind: DecodeKind, type: UInt32) -> Double? {
        // Most M-series temp keys publish as "flt " (32-bit float, little-endian).
        // Older "sp78" is 16-bit signed fixed point (8.8); fan RPM is "fpe2" (UInt16 / 4).
        var b = bytes
        return withUnsafeBytes(of: &b) { raw -> Double? in
            switch (type, kind) {
            case (fourCC("flt "), .floatTemp), (fourCC("flt "), .fpe2Rpm):
                let f = raw.load(as: Float32.self)
                return Double(f)
            case (fourCC("sp78"), .floatTemp):
                let hi = Int8(bitPattern: raw.load(fromByteOffset: 0, as: UInt8.self))
                let lo = raw.load(fromByteOffset: 1, as: UInt8.self)
                return Double(hi) + Double(lo) / 256.0
            case (fourCC("fpe2"), .fpe2Rpm):
                let u: UInt16 = (UInt16(raw.load(fromByteOffset: 0, as: UInt8.self)) << 8)
                              | UInt16(raw.load(fromByteOffset: 1, as: UInt8.self))
                return Double(u) / 4.0
            default:
                // Last-ditch: if it's 4 bytes, try Float32.
                if size == 4 { return Double(raw.load(as: Float32.self)) }
                return nil
            }
        }
    }

    private static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for c in s.utf8.prefix(4) { v = (v << 8) | UInt32(c) }
        return v
    }
    private static func makeFourCC(_ s: String) -> UInt32 { fourCC(s) }
}

private struct SMCKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C rounds SMCKeyInfoData up to 12 bytes (4-byte alignment); Swift would
    // otherwise pack the following field into this tail padding and shrink the
    // parent `SMCKeyData` to 76. Explicit pad keeps the 80-byte ABI.
    var reserved: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0)
    // SMCPLimitData: version/length (UInt16) + cpu/gpu/mem PLimit (UInt32) = 16 bytes.
    // The previous 4×UInt16 (8 bytes) + bogus `padding` shrank the struct to 72,
    // breaking every IOConnectCallStructMethod call (see init's stride guard).
    var pLimitData: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0,0,0,0,0)
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0,
                        0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
}
