import Foundation

/// Parses GeForce NOW console.log lines into game session events.
enum LogParser {
    nonisolated(unsafe) static let launchPattern = /Launch game (.+?) \[([0-9a-fA-F-]{36})\]/
    nonisolated(unsafe) static let libraryPattern = /Found game (.+?) in LIBRARY/
    nonisolated(unsafe) static let shortNamePattern = /"shortName"\s*:\s*"([^"]+)"/
    nonisolated(unsafe) static let executableNamePattern = /"name"\s*:\s*"([^"]+\.exe)"/
    nonisolated(unsafe) static let artworkPattern = #/(https://img\.nvidiagrid\.net/apps/([0-9a-fA-F-]{36})/[^"'\s]+)/#
    nonisolated(unsafe) static let streamerURLPattern = /cmsId=(\d+)&shortName=([a-zA-Z0-9_]+)/
    nonisolated(unsafe) static let appNamePattern = /"appName"\s*:\s*"([^"]+)"/
    nonisolated(unsafe) static let detailsPattern = /"details"\s*:\s*"([^"]+)"/
    nonisolated(unsafe) static let profileNamePattern = /"profileName"\s*:\s*"([^"]+)"/

    enum Event: Equatable {
        case launch(title: String, gfnAppId: String)
        case streamingBegin
        case streamingStop
        case clearingPresence
        case shortName(String)
        case executable(String)
        case artwork(url: URL, gfnAppId: String)
        case libraryGame(String)
        case streamerConfig(cmsId: String, shortName: String)
        case appName(String)
        case presenceDetails(String)
        case profileName(String)
    }

    static func parseLine(_ line: String) -> [Event] {
        var events: [Event] = []

        if line.contains("onStreamingBegin") {
            events.append(.streamingBegin)
        }
        if line.contains("stop streaming called") {
            events.append(.streamingStop)
        }
        if line.contains("Clearing rich presence") {
            events.append(.clearingPresence)
        }

        if let match = line.firstMatch(of: launchPattern) {
            let title = String(match.1).trimmingCharacters(in: .whitespaces)
            let id = String(match.2)
            events.append(.launch(title: title, gfnAppId: id))
        }

        // Library lines can appear multiple times concatenated on one line
        for match in line.matches(of: libraryPattern) {
            let title = String(match.1).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                events.append(.libraryGame(title))
            }
        }

        if let match = line.firstMatch(of: streamerURLPattern) {
            events.append(.streamerConfig(cmsId: String(match.1), shortName: String(match.2)))
        }

        if let match = line.firstMatch(of: shortNamePattern) {
            events.append(.shortName(String(match.1)))
        }

        if let match = line.firstMatch(of: executableNamePattern) {
            events.append(.executable(String(match.1)))
        }

        if let match = line.firstMatch(of: artworkPattern) {
            let urlString = String(match.1)
            let appId = String(match.2)
            // Prefer hero / key art over tiny banners
            if urlString.contains("HERO") || urlString.contains("BOX") || urlString.contains("KEY") {
                if let url = URL(string: urlString.components(separatedBy: ";").first ?? urlString) {
                    events.append(.artwork(url: url, gfnAppId: appId))
                }
            }
        }

        // Avoid picking up generic "GeForceNOW" appName from telemetry
        if line.contains("DiscordService") || line.contains("createInstance") || line.contains("DRSAppName") {
            if let match = line.firstMatch(of: appNamePattern) {
                let name = String(match.1)
                if name != "GeForceNOW" {
                    events.append(.appName(name))
                }
            }
            if let match = line.firstMatch(of: detailsPattern) {
                events.append(.presenceDetails(String(match.1)))
            }
            if let match = line.firstMatch(of: profileNamePattern) {
                events.append(.profileName(String(match.1)))
            }
        } else if let match = line.firstMatch(of: profileNamePattern) {
            events.append(.profileName(String(match.1)))
        }

        return events
    }
}

/// Follows GeForce NOW's console.log and emits session / library updates.
@MainActor
final class LogWatcher {
    private let logDirectory: URL
    private let logFileName = "console.log"

    private var fileHandle: FileHandle?
    private var lineBuffer = LineBuffer()
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: Timer?
    private var watchedInode: UInt64?
    private var pendingSession: GameSession?
    private var artworkByAppId: [String: URL] = [:]
    private var isStreaming = false

    private(set) var currentSession: GameSession?
    private(set) var libraryGames: [String] = []

    var onSessionChanged: ((GameSession?) -> Void)?
    var onLibraryUpdated: (([String]) -> Void)?

    init(logDirectory: URL? = nil) {
        if let logDirectory {
            self.logDirectory = logDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.logDirectory = home
                .appendingPathComponent("Library/Application Support/NVIDIA/GeForceNOW")
        }
    }

    func start() {
        openAndCatchUp()
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        closeHandle()
    }

    // MARK: - File handling

    private static let catchUpBytes: UInt64 = 2 * 1024 * 1024

    private var logURL: URL {
        logDirectory.appendingPathComponent(logFileName)
    }

    /// Opens the log, replays its last ~2 MB to reconstruct the current session and library,
    /// then keeps the handle at the end for live tailing.
    private func openAndCatchUp() {
        closeHandle()
        let url = logURL
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return }

        fileHandle = handle
        watchedInode = inode(of: url)
        lineBuffer = LineBuffer()

        do {
            let size = try handle.seekToEnd()
            let offset = size > Self.catchUpBytes ? size - Self.catchUpBytes : 0
            try handle.seek(toOffset: offset)
            var data = try handle.readToEnd() ?? Data()
            if offset > 0, let newline = data.firstIndex(of: 0x0A) {
                // Starting mid-file: the first line is a fragment.
                data = Data(data[data.index(after: newline)...])
            }

            let previousCallback = onSessionChanged
            onSessionChanged = nil
            process(data: data)
            onSessionChanged = previousCallback
            onSessionChanged?(currentSession)
            onLibraryUpdated?(libraryGames)
        } catch {
            closeHandle()
            return
        }

        startWatching()
    }

    private func closeHandle() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func inode(of url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }

    private func fileSize(of url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
    }

    private func startWatching() {
        source?.cancel()
        source = nil

        guard let handle = fileHandle else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .write, .rename, .delete, .link],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.checkForChanges()
            }
        }
        src.resume()
        source = src
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForChanges()
            }
        }
    }

    private func checkForChanges() {
        guard let handle = fileHandle else {
            openAndCatchUp()
            return
        }
        // Rotated (GFN moves the old log to console.log.bak) or truncated in place.
        if inode(of: logURL) != watchedInode
            || (fileSize(of: logURL) ?? 0) < handle.offsetInFile {
            openAndCatchUp()
            return
        }
        do {
            guard let data = try handle.readToEnd(), !data.isEmpty else { return }
            process(data: data)
        } catch {
            openAndCatchUp()
        }
    }

    private func process(data: Data) {
        for line in lineBuffer.append(data) {
            handleEvents(LogParser.parseLine(line))
        }
    }

    private func handleEvents(_ events: [LogParser.Event]) {
        for event in events {
            switch event {
            case .launch(let title, let gfnAppId):
                var session = GameSession(title: title, gfnAppId: gfnAppId, startedAt: Date())
                if let art = artworkByAppId[gfnAppId] {
                    session.artworkURL = art
                }
                pendingSession = session
                isStreaming = false

            case .streamerConfig(_, let shortName):
                if pendingSession != nil {
                    pendingSession?.shortName = shortName
                }

            case .shortName(let name):
                if pendingSession != nil {
                    pendingSession?.shortName = name
                } else if currentSession != nil {
                    currentSession?.shortName = name
                }

            case .executable(let exe):
                if pendingSession != nil {
                    pendingSession?.executable = exe
                } else if currentSession != nil {
                    currentSession?.executable = exe
                    emitSession()
                }

            case .appName(let name), .presenceDetails(let name), .profileName(let name):
                if pendingSession != nil, pendingSession?.title.isEmpty != false {
                    pendingSession?.title = name
                } else if pendingSession == nil, currentSession == nil {
                    // ignore
                } else if let pending = pendingSession, pending.title != name {
                    // Prefer more specific names if launch title was generic — keep launch title
                    _ = pending
                }

            case .artwork(let url, let gfnAppId):
                artworkByAppId[gfnAppId] = url
                if pendingSession?.gfnAppId == gfnAppId {
                    pendingSession?.artworkURL = url
                }
                if currentSession?.gfnAppId == gfnAppId {
                    currentSession?.artworkURL = url
                    emitSession()
                }

            case .streamingBegin:
                isStreaming = true
                if let pending = pendingSession {
                    currentSession = pending
                    pendingSession = nil
                    emitSession()
                }

            case .streamingStop, .clearingPresence:
                isStreaming = false
                pendingSession = nil
                if currentSession != nil {
                    currentSession = nil
                    emitSession()
                }

            case .libraryGame(let title):
                if !libraryGames.contains(title) {
                    libraryGames.append(title)
                    libraryGames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    onLibraryUpdated?(libraryGames)
                }
            }
        }
    }

    private func emitSession() {
        onSessionChanged?(currentSession)
    }
}

/// Splits a byte stream into complete lines, holding back a trailing partial line
/// (and any UTF-8 character split across reads) until its newline arrives.
struct LineBuffer {
    static let maxPendingBytes = 4 * 1024 * 1024

    private(set) var pending = Data()

    mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        guard let lastNewline = pending.lastIndex(of: 0x0A) else {
            if pending.count > Self.maxPendingBytes {
                pending.removeAll()
            }
            return []
        }

        let text = String(decoding: pending[...lastNewline], as: UTF8.self)
        pending = Data(pending[pending.index(after: lastNewline)...])
        return text.split(separator: "\n").map(String.init)
    }
}
