import Foundation
import CZlib

enum Gzip {
    /// Inflates a gzip member (RFC 1952). Returns nil if the data is not gzip.
    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flg = b[3]
        var i = 10
        if flg & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; let xlen = Int(b[i]) | Int(b[i + 1]) << 8; i += 2 + xlen }
        if flg & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flg & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let isize = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let capacity = max(isize, 64) + 64
        var dst = [UInt8](repeating: 0, count: capacity)
        let body = Array(b[i..<(b.count - 8)])

        var z = z_stream()
        // Negative window bits: raw deflate, the gzip header was parsed above.
        guard inflateInit2_(&z, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var produced = 0
        let rc: Int32 = body.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                z.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
                z.avail_in = UInt32(src.count)
                z.next_out = out.baseAddress
                z.avail_out = UInt32(out.count)
                let r = inflate(&z, Z_FINISH)
                produced = out.count - Int(z.avail_out)
                return r
            }
        }
        guard rc == Z_STREAM_END, produced > 0 else { return nil }
        return Data(dst[0..<produced])
    }
}
