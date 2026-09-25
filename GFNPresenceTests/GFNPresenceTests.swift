import XCTest
@testable import GFNPresence

final class LogParserTests: XCTestCase {
    func testParseLaunchGame() {
        let line = #"2026-09-24 11:59:52.803 INFO  ApplicationClass  Launch game Fortnite® [46bfab06-d864-465d-9e56-2d9e45cdee0a]"#
        let events = LogParser.parseLine(line)
        XCTAssertTrue(events.contains {
            if case .launch(let title, let id) = $0 {
                return title == "Fortnite®" && id == "46bfab06-d864-465d-9e56-2d9e45cdee0a"
            }
            return false
        })
    }

    func testParseStreamingBeginAndStop() {
        XCTAssertTrue(LogParser.parseLine("streamingService  onStreamingBegin").contains(.streamingBegin))
        XCTAssertTrue(
            LogParser.parseLine("streamingService  stop streaming called, wasStreamingStarted: true")
                .contains(.streamingStop)
        )
        XCTAssertTrue(LogParser.parseLine("DiscordService  Clearing rich presence").contains(.clearingPresence))
    }

    func testParseLibraryGamesConcatenated() {
        let line = "LcarsService  Found game Fortnite® in LIBRARY 2026-09-24 Found game Golf With Your Friends in LIBRARY"
        let events = LogParser.parseLine(line)
        let titles = events.compactMap { event -> String? in
            if case .libraryGame(let t) = event { return t }
            return nil
        }
        XCTAssertEqual(titles, ["Fortnite®", "Golf With Your Friends"])
    }

    func testParseExecutableAndShortName() {
        let exeLine = #""name": "FortniteClient-Win64-Shipping.exe""#
        XCTAssertTrue(LogParser.parseLine(exeLine).contains(.executable("FortniteClient-Win64-Shipping.exe")))

        let shortLine = #""shortName": "fortnite_gfn_pc""#
        XCTAssertTrue(LogParser.parseLine(shortLine).contains(.shortName("fortnite_gfn_pc")))
    }

    func testParseArtworkURL() {
        let line = #"https://img.nvidiagrid.net/apps/46bfab06-d864-465d-9e56-2d9e45cdee0a/ZZ/HERO_IMAGE_01_8c12f9ee-12dc-47aa-b372-9fcddee7b21a.jpg;f=webp"#
        let events = LogParser.parseLine(line)
        guard case .artwork(let url, let id)? = events.first else {
            return XCTFail("Expected artwork event")
        }
        XCTAssertEqual(id, "46bfab06-d864-465d-9e56-2d9e45cdee0a")
        XCTAssertTrue(url.absoluteString.contains("HERO_IMAGE"))
        XCTAssertFalse(url.absoluteString.contains(";"))
    }

    func testParseStreamerConfig() {
        let line = "Navigating to streamer url /streamer?launchSource=GeForceNOW&cmsId=100013311&shortName=fortnite_gfn_pc&appLaunchMode=Default"
        let events = LogParser.parseLine(line)
        XCTAssertTrue(events.contains {
            if case .streamerConfig(let cms, let short) = $0 {
                return cms == "100013311" && short == "fortnite_gfn_pc"
            }
            return false
        })
    }
}

final class LogWatcherSessionTests: XCTestCase {
    @MainActor
    func testSessionLifecycleFromLogLines() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GFNPresenceTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("console.log")
        try? "".write(to: logURL, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(logDirectory: dir)
        var sessions: [GameSession?] = []
        watcher.onSessionChanged = { sessions.append($0) }
        watcher.start()

        let chunk = """
        ApplicationClass  Launch game Fortnite® [46bfab06-d864-465d-9e56-2d9e45cdee0a]
        "shortName": "fortnite_gfn_pc"
        "name": "FortniteClient-Win64-Shipping.exe"
        https://img.nvidiagrid.net/apps/46bfab06-d864-465d-9e56-2d9e45cdee0a/ZZ/HERO_IMAGE_01.jpg
        streamingService  onStreamingBegin

        """
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(chunk.utf8))
            try? handle.close()
        }

        // Allow watcher poll / FS events
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if sessions.contains(where: { $0?.title == "Fortnite®" }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertEqual(watcher.currentSession?.title, "Fortnite®")
        XCTAssertEqual(watcher.currentSession?.executable, "FortniteClient-Win64-Shipping.exe")
        XCTAssertEqual(watcher.currentSession?.gfnAppId, "46bfab06-d864-465d-9e56-2d9e45cdee0a")
        XCTAssertNotNil(watcher.currentSession?.artworkURL)

        let stop = "streamingService  stop streaming called, wasStreamingStarted: true\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(stop.utf8))
            try? handle.close()
        }

        let stopDeadline = Date().addingTimeInterval(3)
        while Date() < stopDeadline {
            if watcher.currentSession == nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(watcher.currentSession)
        watcher.stop()
    }

    @MainActor
    func testCatchUpFindsActiveSessionInExistingLog() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GFNPresenceCatchUp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("console.log")
        let preexisting = """
        ApplicationClass  Launch game Cyberpunk 2077® [aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee]
        "name": "Cyberpunk2077.exe"
        streamingService  onStreamingBegin

        """
        try? preexisting.write(to: logURL, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(logDirectory: dir)
        watcher.start()
        XCTAssertEqual(watcher.currentSession?.title, "Cyberpunk 2077®")
        XCTAssertEqual(watcher.currentSession?.executable, "Cyberpunk2077.exe")
        watcher.stop()
    }

    @MainActor
    func testCatchUpIgnoresEndedSession() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GFNPresenceEnded-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("console.log")
        let preexisting = """
        ApplicationClass  Launch game Fortnite® [46bfab06-d864-465d-9e56-2d9e45cdee0a]
        streamingService  onStreamingBegin
        streamingService  stop streaming called, wasStreamingStarted: true
        DiscordService  Clearing rich presence

        """
        try? preexisting.write(to: logURL, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(logDirectory: dir)
        watcher.start()
        XCTAssertNil(watcher.currentSession)
        watcher.stop()
    }
}

final class GameResolverTests: XCTestCase {
    func testNormalizeGameName() {
        XCTAssertEqual("Fortnite®".normalizedGameName(), "fortnite")
        XCTAssertEqual("Baldur's Gate 3".normalizedGameName(), "baldursgate3")
        XCTAssertEqual("Baldur's Gate III".normalizedGameName(), "baldursgate3")
    }

    func testResolveByExecutable() async {
        let catalog = DetectableCatalog()
        await catalog.load(from: [
            DetectableGame(
                id: "1402418703554842694",
                name: "Fortnite",
                aliases: nil,
                iconHash: "abc123",
                executables: [
                    DetectableExecutable(name: "fortniteclient-win64-shipping.exe", isLauncher: false)
                ]
            )
        ])

        let match = await catalog.lookup(
            executable: "FortniteClient-Win64-Shipping.exe",
            title: "Something Else"
        )
        XCTAssertEqual(match?.id, "1402418703554842694")

        let target = GameResolver.resolve(
            title: "Fortnite®",
            executable: "FortniteClient-Win64-Shipping.exe",
            artworkURL: nil,
            startedAt: Date(),
            fallbackClientId: "999",
            catalogGame: match
        )
        XCTAssertEqual(target.clientId, "1402418703554842694")
        XCTAssertEqual(target.details, "Fortnite")
        XCTAssertTrue(target.largeImageKey?.contains("cdn.discordapp.com") == true)
        XCTAssertFalse(target.useStatusDisplayTypeName)
    }

    func testResolveByAlias() async {
        let catalog = DetectableCatalog()
        await catalog.load(from: [
            DetectableGame(
                id: "1137125502985961543",
                name: "Baldur's Gate III",
                aliases: ["Baldur's Gate 3"],
                iconHash: "hash",
                executables: nil
            )
        ])

        let match = await catalog.lookup(executable: nil, title: "Baldur's Gate 3")
        XCTAssertEqual(match?.name, "Baldur's Gate III")
    }

    func testFallbackForUnknownGame() {
        let art = URL(string: "https://img.nvidiagrid.net/apps/x/ZZ/HERO.jpg")!
        let target = GameResolver.resolve(
            title: "Anachronox",
            executable: nil,
            artworkURL: art,
            startedAt: Date(),
            fallbackClientId: "111222333",
            catalogGame: nil
        )
        XCTAssertEqual(target.clientId, "111222333")
        XCTAssertEqual(target.details, "Anachronox")
        XCTAssertEqual(target.largeImageKey, art.absoluteString)
        XCTAssertTrue(target.useStatusDisplayTypeName)
    }
}

final class LineBufferTests: XCTestCase {
    func testHoldsPartialLineUntilNewline() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("streamingService  stop strea".utf8)), [])
        XCTAssertEqual(buffer.append(Data("ming called\nnext".utf8)), ["streamingService  stop streaming called"])
        XCTAssertEqual(buffer.pending, Data("next".utf8))
    }

    func testMultiByteCharacterSplitAcrossReads() {
        var buffer = LineBuffer()
        let line = Data("Launch game Fortnite® [46bfab06-d864-465d-9e56-2d9e45cdee0a]\n".utf8)
        let registered = line.firstRange(of: Data("®".utf8))!
        let splitPoint = registered.lowerBound + 1

        XCTAssertEqual(buffer.append(line[..<splitPoint]), [])
        let lines = buffer.append(line[splitPoint...])
        XCTAssertEqual(lines, ["Launch game Fortnite® [46bfab06-d864-465d-9e56-2d9e45cdee0a]"])
    }

    func testInvalidUTF8DoesNotDropOtherLines() {
        var buffer = LineBuffer()
        var data = Data([0xFF, 0xFE, 0x0A])
        data.append(Data("streamingService  onStreamingBegin\n".utf8))
        let lines = buffer.append(data)
        XCTAssertEqual(lines.last, "streamingService  onStreamingBegin")
    }

    func testDiscardsRunawayLineWithoutNewline() {
        var buffer = LineBuffer()
        _ = buffer.append(Data(count: LineBuffer.maxPendingBytes + 1))
        XCTAssertTrue(buffer.pending.isEmpty)
    }
}

final class DiscordSocketOwnershipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Unix socket paths are limited to 104 bytes, so keep this short.
        directory = URL(fileURLWithPath: "/private/tmp/gfnp-\(getpid())-\(Int.random(in: 0..<100_000))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAcceptsSocketOwnedByCurrentUser() throws {
        let path = directory.appendingPathComponent("s").path
        let fd = try bindSocket(at: path)
        defer { close(fd) }
        XCTAssertTrue(DiscordIPC.isOwnedSocket(atPath: path))
    }

    func testRejectsRegularFile() throws {
        let path = directory.appendingPathComponent("f").path
        FileManager.default.createFile(atPath: path, contents: Data())
        XCTAssertFalse(DiscordIPC.isOwnedSocket(atPath: path))
    }

    func testRejectsSymlinkToSocket() throws {
        let target = directory.appendingPathComponent("s").path
        let fd = try bindSocket(at: target)
        defer { close(fd) }
        let link = directory.appendingPathComponent("l").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertFalse(DiscordIPC.isOwnedSocket(atPath: link))
    }

    func testRejectsMissingPath() {
        XCTAssertFalse(DiscordIPC.isOwnedSocket(atPath: directory.appendingPathComponent("missing").path))
    }

    private func bindSocket(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            bytes.withUnsafeBytes { src in _ = memcpy(ptr, src.baseAddress!, bytes.count) }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard fd >= 0, result == 0 else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return fd
    }
}
