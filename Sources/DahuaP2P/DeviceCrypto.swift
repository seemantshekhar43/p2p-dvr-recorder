import Foundation
import Crypto
import _CryptoExtras

/// Cryptography used by the Easy4ip handshake, as implemented by the official
/// clients (see re/NOTES.md for the evidence trail).
public enum DeviceCrypto {
    static let deviceInfoKey = Data("kRjmsUB&ezmdGLL67H#$ojw@XflcaIaf".utf8)
    static let deviceInfoIV = Data("MydvJw*Iw1w&i^kk".utf8)
    static let ipEncryptIV = Data("2z52*lk9o6HRyJrf".utf8)

    public struct DeviceInfo: Decodable, Sendable {
        public var httpport: Int?
        public var privport: Int?
        public var randsalt: String?
        public var rtspport: Int?
        public var tlsprivport: Int?
    }

    /// Decrypts the base64 `Info` field of `/info/device/{serial}`.
    public static func decryptDeviceInfo(_ b64: String) throws -> DeviceInfo {
        guard let ct = Data(base64Encoded: b64) else { throw P2PError.protocolError("device info is not base64") }
        let pt = try aesOFB(key: deviceInfoKey, iv: deviceInfoIV, data: ct)
        // The JSON may carry trailing padding/garbage; cut at the last brace.
        guard let end = pt.lastIndex(of: UInt8(ascii: "}")) else { throw P2PError.protocolError("device info is not JSON") }
        let json = pt[pt.startIndex...end]
        return try JSONDecoder().decode(DeviceInfo.self, from: Data(json))
    }

    /// key = uppercase hex MD5("user:Login to {randsalt}:pass"), used as raw ASCII bytes.
    public static func deviceKey(user: String, password: String, randsalt: String) -> Data {
        let raw = "\(user):Login to \(randsalt):\(password)"
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return Data(digest.map { String(format: "%02X", $0) }.joined().utf8)
    }

    public static func randomNonce() -> UInt32 {
        var g = SystemRandomNumberGenerator()
        return g.next()
    }

    public static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// AES-256-OFB under PBKDF2-SHA256(key, "\(nonce)", 20000), base64.
    public static func encryptAddr(key: Data, nonce: UInt32, _ plain: String) throws -> String {
        let dk = pbkdf2SHA256(password: key, salt: Data(String(nonce).utf8), iterations: 20000, length: 32)
        return try aesOFB(key: dk, iv: ipEncryptIV, data: Data(plain.utf8)).base64EncodedString()
    }

    public static func decryptAddr(key: Data, nonce: UInt32, _ b64: String) throws -> String {
        guard let ct = Data(base64Encoded: b64) else { throw P2PError.protocolError("address is not base64") }
        let dk = pbkdf2SHA256(password: key, salt: Data(String(nonce).utf8), iterations: 20000, length: 32)
        let pt = try aesOFB(key: dk, iv: ipEncryptIV, data: ct)
        return String(decoding: pt, as: UTF8.self)
    }

    /// The `<CreateDate>…<UserName>` fragment that authenticates a channel request.
    public static func deviceAuthXML(user: String, key: Data, nonce: UInt32, randsalt: String, payload: String, now: Date = Date()) -> String {
        let curdate = Int(now.timeIntervalSince1970)
        let message = "\(nonce)\(curdate)\(payload)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        let auth = Data(mac).base64EncodedString()
        return "<CreateDate>\(curdate)</CreateDate><DevAuth>\(auth)</DevAuth><Nonce>\(nonce)</Nonce><RandSalt>\(randsalt)</RandSalt><UserName>\(user)</UserName>"
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        // RFC 8018 PBKDF2 with HMAC-SHA256 (swift-crypto has no public PBKDF2).
        let key = SymmetricKey(data: password)
        var out = Data()
        var block: UInt32 = 1
        while out.count < length {
            var msg = salt
            withUnsafeBytes(of: block.bigEndian) { msg.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: msg, using: key))
            var t = [UInt8](u)
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[u.startIndex + i] }
                }
            }
            out.append(contentsOf: t)
            block += 1
        }
        return out.prefix(length)
    }

    /// AES in OFB mode (a stream mode: encrypt == decrypt, no padding).
    /// swift-crypto has no OFB, so the keystream is built from single-block
    /// AES: O_0 = IV, O_i = E_K(O_{i-1}). One CBC block under a zero IV is
    /// exactly E_K(block).
    public static func aesOFB(key: Data, iv: Data, data: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else {
            throw P2PError.protocolError("AES init failed (key \(key.count) iv \(iv.count))")
        }
        let k = SymmetricKey(data: key)
        let zero = try AES._CBC.IV(ivBytes: [UInt8](repeating: 0, count: 16))
        var block = [UInt8](iv)
        var out = [UInt8](data)
        var i = 0
        while i < out.count {
            block = [UInt8](try AES._CBC.encrypt(block, using: k, iv: zero, noPadding: true))
            let n = min(16, out.count - i)
            for j in 0..<n { out[i + j] ^= block[j] }
            i += n
        }
        return Data(out)
    }

    public static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha1Base64(_ s: String) -> String {
        Data(Insecure.SHA1.hash(data: Data(s.utf8))).base64EncodedString()
    }
}
