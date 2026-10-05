import Foundation
import Darwin
import CoreGraphics

// macOS virtual key positions -> USB HID keyboard usages (main keyboard only).
// The existing layout map determines which position and Shift state each character needs.
enum VirtualKeyboard {
    static let usages: [CGKeyCode: UInt8] = [
        0:4, 1:22, 2:7, 3:9, 4:11, 5:10, 6:29, 7:27, 8:6, 9:25, 10:100,
        11:5, 12:20, 13:26, 14:8, 15:21, 16:28, 17:23, 18:30, 19:31,
        20:32, 21:33, 22:35, 23:34, 24:46, 25:38, 26:36, 27:45, 28:37,
        29:39, 30:48, 31:18, 32:24, 33:47, 34:12, 35:19, 36:40, 37:15,
        38:13, 39:52, 40:14, 41:51, 42:49, 43:54, 44:56, 45:17, 46:16,
        47:55, 48:43, 49:44, 50:53
    ]
    static let socketPath = "/var/run/local.keytyper.virtual-keyboard.sock"
    static let daemonPlist = "/Library/LaunchDaemons/local.keytyper.virtual-keyboard.plist"

    enum Status {
        case ready, notInstalled, notResponding, driverNotReady

        var title: String {
            switch self {
            case .ready: return "Virtual Keyboard is ready"
            case .notInstalled: return "Virtual Keyboard is not set up"
            case .notResponding: return "Virtual Keyboard helper is not responding"
            case .driverNotReady: return "Virtual Keyboard driver is not active yet"
            }
        }

        var help: String {
            switch self {
            case .ready:
                return "Use Control+\\ or Type Clipboard to type. For a first test, choose Test abc123 in 3 seconds, then click the text field in your remote session."
            case .notInstalled:
                return "Choose Set Up Virtual Keyboard… from the KeyTyper menu."
            case .notResponding:
                return "The helper is installed but did not answer. Wait a few seconds and check again. If this continues, run Set Up Virtual Keyboard… again."
            case .driverNotReady:
                return "The helper is running, but the Karabiner virtual keyboard driver is not active. Approve its system extension in System Settings (Privacy & Security, or General > Login Items & Extensions > Driver Extensions), then check again. Restart only if macOS asks."
            }
        }
    }

    /// Asks the helper for its state. Blocks for up to 2 seconds; call off the main thread.
    static func status() -> Status {
        guard FileManager.default.fileExists(atPath: daemonPlist) else { return .notInstalled }
        switch exchange([1, 0, 0, 0, 0, 0, 0, 0]) {
        case 0: return .ready
        case 1: return .driverNotReady
        default: return .notResponding
        }
    }

    /// Sends one packet and returns the helper's reply byte, or nil if there was no reply.
    private static func exchange(_ packet: [UInt8]) -> UInt8? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { path in
            for (index, byte) in socketPath.utf8.enumerated() { path[index] = byte }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        let sent = packet.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == packet.count else { return nil }
        var reply: UInt8 = 255
        return recv(fd, &reply, 1, 0) == 1 ? reply : nil
    }

    static func press(_ stroke: KeyStroke, delay: TimeInterval) -> Bool {
        guard let usage = usages[stroke.keyCode] else { return false }
        let gap = UInt16(max(0, min(500, delay * 1000)))
        // Preserve the proven POC's 80 ms physical key hold.
        return exchange([1, 1, usage, stroke.shift ? 2 : 0, 80, 0, UInt8(gap & 255), UInt8(gap >> 8)]) == 0
    }
}
