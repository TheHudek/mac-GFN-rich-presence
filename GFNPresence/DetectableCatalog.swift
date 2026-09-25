import Foundation

struct DetectableGame: Decodable, Sendable {
    let id: String
    let name: String
    let aliases: [String]?
    let iconHash: String?
    let executables: [DetectableExecutable]?

    enum CodingKeys: String, CodingKey {
        case id, name, aliases, executables
        case iconHash = "icon_hash"
    }
}

struct DetectableExecutable: Decodable, Sendable {
    let name: String
    let isLauncher: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case isLauncher = "is_launcher"
    }
}

/// Downloads and caches Discord's detectable applications list.
actor DetectableCatalog {
    private static let remoteURL = URL(string: "https://discord.com/api/v10/applications/detectable")!
    private static let cacheMaxAge: TimeInterval = 7 * 24 * 60 * 60 // 1 week

    private var byExecutable: [String: DetectableGame] = [:]
    private var byNormalizedName: [String: DetectableGame] = [:]
    private var loaded = false

    private var cacheDirectory: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GFNPresence")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var cacheURL: URL {
        cacheDirectory.appendingPathComponent("detectable.json")
    }

    private var stampURL: URL {
        cacheDirectory.appendingPathComponent("detectable.stamp")
    }

    func ensureLoaded() async {
        if loaded { return }
        await load()
    }

    func lookup(executable: String?, title: String) -> DetectableGame? {
        if let executable {
            let key = executable.lowercased()
            if let game = byExecutable[key] {
                return game
            }
            // Also try basename without path separators
            let base = (executable as NSString).lastPathComponent.lowercased()
            if let game = byExecutable[base] {
                return game
            }
        }

        let normalized = title.normalizedGameName()
        if let game = byNormalizedName[normalized] {
            return game
        }
        return nil
    }

    func refreshIfNeeded() async {
        if shouldRefresh() {
            await downloadAndCache()
            await loadFromCache()
        } else if !loaded {
            await load()
        }
    }

    // MARK: - Loading

    private func load() async {
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            await loadFromCache()
            if shouldRefresh() {
                await downloadAndCache()
                await loadFromCache()
            }
        } else {
            await downloadAndCache()
            await loadFromCache()
        }
        loaded = true
    }

    private func shouldRefresh() -> Bool {
        guard let data = try? Data(contentsOf: stampURL),
              let stamp = Double(String(data: data, encoding: .utf8) ?? "") else {
            return true
        }
        return Date().timeIntervalSince1970 - stamp > Self.cacheMaxAge
    }

    private func downloadAndCache() async {
        do {
            var request = URLRequest(url: Self.remoteURL)
            request.setValue("GFNPresence/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return
            }
            try data.write(to: cacheURL, options: .atomic)
            let stamp = String(Date().timeIntervalSince1970)
            try stamp.data(using: .utf8)?.write(to: stampURL, options: .atomic)
        } catch {
            // Keep existing cache on failure
        }
    }

    private func loadFromCache() async {
        guard let data = try? Data(contentsOf: cacheURL),
              let games = try? JSONDecoder().decode([DetectableGame].self, from: data) else {
            return
        }
        rebuildIndexes(from: games)
    }

    /// Test helper / bootstrap from in-memory JSON.
    func load(from games: [DetectableGame]) {
        rebuildIndexes(from: games)
        loaded = true
    }

    private func rebuildIndexes(from games: [DetectableGame]) {
        var exeMap: [String: DetectableGame] = [:]
        var nameMap: [String: DetectableGame] = [:]

        for game in games {
            let nameKey = game.name.normalizedGameName()
            if !nameKey.isEmpty {
                nameMap[nameKey] = game
            }
            for alias in game.aliases ?? [] {
                let aliasKey = alias.normalizedGameName()
                if !aliasKey.isEmpty {
                    nameMap[aliasKey] = game
                }
            }
            for exe in game.executables ?? [] {
                if exe.isLauncher == true { continue }
                let key = exe.name.lowercased()
                // Prefer non-launcher; first wins unless overwritten by non-launcher
                if exeMap[key] == nil {
                    exeMap[key] = game
                }
            }
        }

        byExecutable = exeMap
        byNormalizedName = nameMap
    }
}

enum GameResolver {
    /// Public GeForce NOW logo used as the small Discord asset.
    static let gfnLogoURL = "https://img.nvidiagrid.net/apps/1ffc1b9b-53c6-46dd-81d0-6ba8b1514988/ZZ/MARQUEE_HERO_IMAGE_01_5c2f7780-7dd1-4117-af45-3afd26bd7468.jpg"

    static func resolve(
        title: String,
        executable: String?,
        artworkURL: URL?,
        startedAt: Date,
        fallbackClientId: String,
        catalogGame: DetectableGame?
    ) -> PresenceTarget {
        if let game = catalogGame {
            let largeImage: String?
            if let hash = game.iconHash, !hash.isEmpty {
                largeImage = "https://cdn.discordapp.com/app-icons/\(game.id)/\(hash).png"
            } else if let artworkURL {
                largeImage = artworkURL.absoluteString
            } else {
                largeImage = nil
            }

            return PresenceTarget(
                clientId: game.id,
                details: game.name,
                state: "via GeForce NOW",
                largeImageKey: largeImage,
                largeImageText: game.name,
                smallImageKey: gfnLogoURL,
                smallImageText: "via GeForce NOW",
                startedAt: startedAt,
                useStatusDisplayTypeName: false
            )
        }

        // Fallback: user's Discord developer application
        let largeImage = artworkURL?.absoluteString
        return PresenceTarget(
            clientId: fallbackClientId,
            details: title,
            state: "via GeForce NOW",
            largeImageKey: largeImage,
            largeImageText: title,
            smallImageKey: gfnLogoURL,
            smallImageText: "via GeForce NOW",
            startedAt: startedAt,
            useStatusDisplayTypeName: true
        )
    }
}
