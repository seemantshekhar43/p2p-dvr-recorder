import Foundation
import DahuaP2P
import TunnelKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// nvr-tunnel: keeps one InstaOn relay tunnel to the DVR alive and exposes the
// DVR's RTSP port on 127.0.0.1 for ffmpeg. Reconnects forever with backoff.
//
// Environment:
//   CAM_SERIAL    InstaOn serial (required)
//   CAM_USER      default "admin"
//   CAM_PASSWORD  required
//   NVR_LISTEN    local port, default 1554
//   NVR_REMOTE    device port, default 554
//   NVR_CLOUD     instaon | easy4ip | auto (try both, default)
//   NVR_BUSY_RETRY seconds to keep retrying "device busy", default 120
//   CAM_PUNCH=1   opt in to the STUN punch (relay is the verified path)

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    FileHandle.standardError.write(Data("\(f.string(from: Date())) \(s)\n".utf8))
}

let env = ProcessInfo.processInfo.environment
guard let serial = env["CAM_SERIAL"], !serial.isEmpty, let password = env["CAM_PASSWORD"], !password.isEmpty else {
    log("CAM_SERIAL and CAM_PASSWORD are required")
    exit(2)
}
let user = env["CAM_USER"] ?? "admin"
let listenPort = UInt16(env["NVR_LISTEN"] ?? "") ?? 1554
let remotePort = UInt32(env["NVR_REMOTE"] ?? "") ?? 554

final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Tunnel?
    var tunnel: Tunnel? { get { lock.withLock { t } } set { lock.withLock { t = newValue } } }
}
let current = Current()

let forwarder: LocalForwarder
do {
    forwarder = try LocalForwarder(port: listenPort, remotePort: remotePort, log: log, tunnel: { current.tunnel })
} catch {
    log("cannot listen: \(error)")
    exit(1)
}

nonisolated(unsafe) var stopping = false
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("signal \(sig), shutting down")
        stopping = true
        current.tunnel?.close("shutdown")
        forwarder.stop()
        exit(0)
    }
    src.resume()
    sources.append(src)
}

var opts = Tunnel.Options(serial: serial, username: user, password: password)
opts.mode = .relay
// The device holds a closed relay session for ~15-20 s; keep retrying "busy" well past that.
opts.busyRetry = TimeInterval(env["NVR_BUSY_RETRY"] ?? "") ?? 120
switch env["NVR_CLOUD"] ?? "auto" {
case "instaon": opts.clouds = [.instaon]
case "easy4ip": opts.clouds = [.easy4ip]
default: break
}
opts.log = { s in if !s.hasPrefix(">>>") && !s.hasPrefix("<<<") && !s.contains("realm") { log(s) } }

Task {
    var backoff = 2.0
    while !stopping {
        let started = Date()
        do {
            log("opening relay tunnel")
            let tunnel = try await Tunnel.open(opts)
            current.tunnel = tunnel
            log("tunnel up via \(tunnel.handshake.peer) (rtsp \(tunnel.rtspPort) -> 127.0.0.1:\(listenPort))")
            while !tunnel.isClosed && !stopping { try await Task.sleep(nanoseconds: 1_000_000_000) }
            log("tunnel closed: \(tunnel.closeReason ?? "unknown")")
            current.tunnel = nil
        } catch {
            log("tunnel open failed: \(error)")
        }
        // A tunnel that stayed up a while earns a fast retry; repeated failures back off.
        backoff = Date().timeIntervalSince(started) > 60 ? 2 : min(backoff * 2, 30)
        log("reconnecting in \(Int(backoff)) s")
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
    }
}

dispatchMain()
