import Foundation
import Darwin

/// Minimal Discord Rich Presence client over the local IPC unix socket.
final class DiscordIPC: @unchecked Sendable {
    enum Opcode: UInt32 {
        case handshake = 0
        case frame = 1
        case close = 2
        case ping = 3
        case pong = 4
    }

    enum IPCError: Error, CustomStringConvertible {
        case socketNotFound
        case handshakeFailed
        case sendFailed
        case discordRejected(String)

        var description: String {
            switch self {
            case .socketNotFound:
                return "Discord IPC socket not found — is Discord open?"
            case .handshakeFailed:
                return "Discord handshake failed"
            case .sendFailed:
                return "Failed to send activity to Discord"
            case .discordRejected(let msg):
                return "Discord rejected activity: \(msg)"
            }
        }
    }

    /// Serial queue: every request is enqueued immediately and runs in submission order,
    /// so a clear issued after a set can never be overtaken by it.
    private let queue = DispatchQueue(label: "com.thehudek.gfnpresence.discord-ipc")
    private var socketFD: Int32 = -1
    private var currentClientId: String?
    private var nonceCounter: UInt64 = 0
    private var isHandshaken = false

    func setActivity(
        _ target: PresenceTarget,
        completion: @escaping @Sendable (Result<Void, IPCError>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            completion(self.setActivityLocked(target))
        }
    }

    func clearActivity() {
        queue.async { [weak self] in
            self?.clearActivityLocked()
        }
    }

    /// Blocks until the activity is cleared and the socket closed. Used when quitting.
    func clearAndDisconnectNow() {
        queue.sync {
            clearActivityLocked()
            closeSocket()
        }
    }

    // MARK: - Locked operations

    private func setActivityLocked(_ target: PresenceTarget) -> Result<Void, IPCError> {
        if currentClientId != target.clientId || !isHandshaken {
            closeSocket()
            if let err = connectAndHandshake(clientId: target.clientId) {
                return .failure(err)
            }
        }

        var activity: [String: Any] = [
            "details": target.details,
            "timestamps": [
                // Discord expects milliseconds
                "start": Int(target.startedAt.timeIntervalSince1970 * 1000)
            ]
        ]

        if let state = target.state {
            activity["state"] = state
        }

        if target.useStatusDisplayTypeName {
            activity["status_display_type"] = 2
        }

        var assets: [String: Any] = [:]
        if let large = target.largeImageKey {
            assets["large_image"] = large
            if let text = target.largeImageText {
                assets["large_text"] = text
            }
        }
        if let small = target.smallImageKey {
            assets["small_image"] = small
            if let text = target.smallImageText {
                assets["small_text"] = text
            }
        }
        if !assets.isEmpty {
            activity["assets"] = assets
        }

        let nonce = nextNonce()
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(getpid()),
                "activity": activity
            ],
            "nonce": nonce
        ]

        guard sendFrame(opcode: .frame, json: payload) else {
            return .failure(.sendFailed)
        }

        // Read response — success has evt: null; errors have evt: ERROR
        if let (_, data) = readFrame(timeoutMs: 2000),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let evt = obj["evt"] as? String, evt == "ERROR" {
                let message = (obj["data"] as? [String: Any])?["message"] as? String ?? "unknown"
                closeSocket()
                return .failure(.discordRejected(message))
            }
        }

        return .success(())
    }

    private func clearActivityLocked() {
        guard isHandshaken, socketFD >= 0 else {
            closeSocket()
            return
        }

        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(getpid()),
                "activity": NSNull()
            ],
            "nonce": nextNonce()
        ]

        _ = sendFrame(opcode: .frame, json: payload)
        _ = readFrame(timeoutMs: 1000)
    }

    // MARK: - Connection

    private func connectAndHandshake(clientId: String) -> IPCError? {
        guard let fd = openDiscordSocket() else {
            return .socketNotFound
        }
        socketFD = fd
        currentClientId = clientId

        let handshake: [String: Any] = [
            "v": 1,
            "client_id": clientId
        ]

        guard sendFrame(opcode: .handshake, json: handshake) else {
            closeSocket()
            return .handshakeFailed
        }

        guard let (_, data) = readFrame(timeoutMs: 3000),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["evt"] as? String) == "READY" else {
            closeSocket()
            return .handshakeFailed
        }

        isHandshaken = true
        return nil
    }

    /// Only trust a real socket (not a symlink) owned by the current user.
    static func isOwnedSocket(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    private func openDiscordSocket() -> Int32? {
        for path in socketPaths() where Self.isOwnedSocket(atPath: path) {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            // Writing to a socket Discord has closed must return EPIPE instead of killing the app.
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = path.utf8CString
            let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxPath else {
                Darwin.close(fd)
                continue
            }

            withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                pathBytes.withUnsafeBytes { src in
                    _ = memcpy(ptr, src.baseAddress!, pathBytes.count)
                }
            }

            #if os(macOS)
            addr.sun_len = UInt8(
                MemoryLayout<UInt8>.size
                    + MemoryLayout<sa_family_t>.size
                    + pathBytes.count
            )
            #endif

            let sockLen = socklen_t(
                MemoryLayout<UInt8>.size
                    + MemoryLayout<sa_family_t>.size
                    + pathBytes.count
            )

            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    connect(fd, sockPtr, sockLen)
                }
            }

            if result == 0 {
                return fd
            }
            Darwin.close(fd)
        }
        return nil
    }

    private func socketPaths() -> [String] {
        var paths: [String] = []
        var bases: [String] = []

        // No world-writable /tmp: another local account could plant a fake socket there.
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            bases.append(tmp)
        }
        bases.append(FileManager.default.temporaryDirectory.path)
        bases.append(NSHomeDirectory() + "/Library/Application Support/discord")

        // Deduplicate while keeping order
        var seen = Set<String>()
        for base in bases {
            let normalized = (base as NSString).standardizingPath
            guard seen.insert(normalized).inserted else { continue }
            for i in 0..<10 {
                paths.append((normalized as NSString).appendingPathComponent("discord-ipc-\(i)"))
            }
        }
        return paths
    }

    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1
        isHandshaken = false
        currentClientId = nil
    }

    // MARK: - Framing

    private func sendFrame(opcode: Opcode, json: [String: Any]) -> Bool {
        guard socketFD >= 0,
              let body = try? JSONSerialization.data(withJSONObject: json) else {
            return false
        }

        var header = Data(count: 8)
        header.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: opcode.rawValue.littleEndian, toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(body.count).littleEndian, toByteOffset: 4, as: UInt32.self)
        }

        let packet = header + body
        let written = packet.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return Darwin.write(socketFD, base, packet.count)
        }

        if written != packet.count {
            closeSocket()
            return false
        }
        return true
    }

    private func readFrame(timeoutMs: Int32) -> (Opcode, Data)? {
        guard socketFD >= 0 else { return nil }

        var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, timeoutMs)
        guard pr > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var header = [UInt8](repeating: 0, count: 8)
        guard readExact(&header, count: 8, timeoutMs: timeoutMs) else {
            closeSocket()
            return nil
        }

        let opRaw = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let length = Int(header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard length >= 0, length < 1_000_000,
              let opcode = Opcode(rawValue: opRaw) else {
            closeSocket()
            return nil
        }

        var bodyBytes = [UInt8](repeating: 0, count: length)
        if length > 0 {
            guard readExact(&bodyBytes, count: length, timeoutMs: timeoutMs) else {
                closeSocket()
                return nil
            }
        }
        return (opcode, Data(bodyBytes))
    }

    private func readExact(_ buffer: inout [UInt8], count: Int, timeoutMs: Int32) -> Bool {
        var offset = 0
        while offset < count {
            var pfd = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, timeoutMs)
            guard pr > 0 else { return false }

            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(socketFD, base.advanced(by: offset), count - offset)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    private func nextNonce() -> String {
        nonceCounter += 1
        return "gfn-\(nonceCounter)-\(UUID().uuidString)"
    }
}
