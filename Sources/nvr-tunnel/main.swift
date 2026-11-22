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
//   NVR_ROTATE_MINUTES re-open the relay session after this long (the relay expires it at about 40 min), default 36, 0 = off
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

// The InstaOn relay drops every session after about 40 minutes (observed: 40.5 min, 11 times in 11 hours). Rather than let it
// die mid-stream (about 30 s of lost footage each time), open a fresh session a little before that. 0 disables.
let rotateAfter = (Double(env["NVR_ROTATE_MINUTES"] ?? "") ?? 36) * 60

Task {
    var backoff = 2.0
    while !stopping {
        let started = Date()
        var rotated = false
        do {
            log("opening relay tunnel")
            var tunnel = try await Tunnel.open(opts)
            current.tunnel = tunnel
            var upSince = Date()
            log("tunnel up via \(tunnel.handshake.peer) (rtsp \(tunnel.rtspPort) -> 127.0.0.1:\(listenPort))")
            while !tunnel.isClosed && !stopping {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard rotateAfter > 0, !tunnel.isClosed, Date().timeIntervalSince(upSince) >= rotateAfter else { continue }
                log("rotating the tunnel after \(Int(Date().timeIntervalSince(upSince) / 60)) min, before the relay session expires")
                var next = opts
                next.busyRetry = 6
                if let fresh = try? await Tunnel.open(next) {
                    // Make before break: new connections already use the fresh session; the old one is closed right after, so the
                    // recorders (which reconnect on their own) find the new tunnel waiting.
                    current.tunnel = fresh
                    tunnel.close("rotated")
                    tunnel = fresh
                    upSince = Date()
                    log("tunnel up via \(fresh.handshake.peer) (rotated without a gap in the tunnel)")
                } else {
                    log("the DVR did not accept a second session, closing the old one first")
                    rotated = true
                    tunnel.close("rotated")
                }
            }
            log("tunnel closed: \(tunnel.closeReason ?? "unknown")")
            current.tunnel = nil
        } catch {
            log("tunnel open failed: \(error)")
        }
        // A planned rotation reconnects at once. A tunnel that stayed up a while earns a fast retry; repeated failures back off.
        backoff = rotated ? 0 : (Date().timeIntervalSince(started) > 60 ? 2 : min(backoff * 2, 30))
        if backoff > 0 { log("reconnecting in \(Int(backoff)) s"); try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000)) }
    }
}

dispatchMain()
