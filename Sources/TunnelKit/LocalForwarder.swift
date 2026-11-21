import Foundation
import DahuaP2P
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Exposes a device port on a local TCP port (127.0.0.1) so ffmpeg can use the tunnel.
/// Plain BSD sockets: one accept thread, one reader thread per client.
public final class LocalForwarder: @unchecked Sendable {
    private let listenFd: Int32
    private let tunnelProvider: @Sendable () -> Tunnel?
    private let remotePort: UInt32
    private let log: @Sendable (String) -> Void
    private var stopped = false

    /// `tunnel` is asked for per client, so the listener survives tunnel reconnects.
    public init(port: UInt16, remotePort: UInt32, log: @escaping @Sendable (String) -> Void, tunnel: @escaping @Sendable () -> Tunnel?) throws {
        self.tunnelProvider = tunnel
        self.remotePort = remotePort
        self.log = log
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw P2PError.socket("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var sa = sockaddr_in()
        #if canImport(Darwin)
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr)
        let rc = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else {
            let e = String(cString: strerror(errno)); sysCloseFd(fd)
            throw P2PError.socket("bind/listen 127.0.0.1:\(port): \(e)")
        }
        listenFd = fd
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    private func acceptLoop() {
        while !stopped {
            let c = accept(listenFd, nil, nil)
            if c < 0 { if stopped { return }; continue }
            var one: Int32 = 1
            setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            handle(c)
        }
    }

    private func handle(_ client: Int32) {
        let remotePort = self.remotePort, log = self.log
        guard let tunnel = tunnelProvider(), !tunnel.isClosed else {
            log("client refused: tunnel is down")
            sysCloseFd(client)
            return
        }
        Task {
            do {
                let realm = try await tunnel.connect(port: remotePort)
                log("local client → realm \(String(realm.id, radix: 16))")
                // device → client
                Task.detached {
                    while let d = await realm.read() {
                        if !Self.sendAll(client, d) { break }
                    }
                    shutdown(client, Int32(SHUT_RDWR))
                }
                // client → device
                Thread.detachNewThread {
                    var buf = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = recv(client, &buf, buf.count, 0)
                        if n <= 0 { break }
                        do { try realm.write(Data(buf[0..<n])) } catch { break }
                    }
                    realm.close()
                    sysCloseFd(client)
                }
            } catch {
                log("forward failed: \(error)")
                sysCloseFd(client)
            }
        }
    }

    private static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var off = 0
        let bytes = [UInt8](data)
        while off < bytes.count {
            #if canImport(Darwin)
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + off, bytes.count - off, flags) }
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    public func stop() { stopped = true; shutdown(listenFd, Int32(SHUT_RDWR)); sysCloseFd(listenFd) }
}

private func sysCloseFd(_ fd: Int32) {
    #if canImport(Darwin)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.close(fd)
    #endif
}
