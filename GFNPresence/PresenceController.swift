import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class PresenceController {
    // Persisted settings
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled) }
    }

    var fallbackClientId: String {
        didSet { UserDefaults.standard.set(fallbackClientId, forKey: Keys.fallbackClientId) }
    }

    var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            updateLoginItem()
        }
    }

    enum DiscordStatus: Equatable {
        case idle
        case connecting
        case connected
        case needsFallbackId
        case error(String)
    }

    // Runtime state
    private(set) var detectedSession: GameSession?
    private(set) var manualOverride: GameSession?
    private(set) var libraryGames: [String] = []
    private(set) var isShowingPresence: Bool = false
    private(set) var catalogReady: Bool = false
    private(set) var discordStatus: DiscordStatus = .idle
    private(set) var currentTitle: String?
    private(set) var currentArtworkURL: URL?

    var isManual: Bool { manualOverride != nil }

    /// The game GFN Presence would show if presence were on.
    var pendingTitle: String? { manualOverride?.title ?? detectedSession?.title }

    private let logWatcher: LogWatcher
    private let discordIPC = DiscordIPC()
    private let catalog = DetectableCatalog()
    private var desiredTarget: PresenceTarget?
    /// Bumped on every recompute so a slower, older `apply` can't overwrite newer state.
    private var applyGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var keepAliveTimer: Timer?

    private enum Keys {
        static let enabled = "gfnpresence.isEnabled"
        static let fallbackClientId = "gfnpresence.fallbackClientId"
    }

    /// Placeholder — replace with your Discord Developer Application ID (see README).
    static let defaultFallbackClientId = "0000000000000000000"

    init(logWatcher: LogWatcher = LogWatcher()) {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.enabled) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: Keys.enabled)
        }
        let storedId = defaults.string(forKey: Keys.fallbackClientId) ?? ""
        self.fallbackClientId = storedId.isEmpty ? Self.defaultFallbackClientId : storedId
        self.logWatcher = logWatcher

        let status = SMAppService.mainApp.status
        self.launchesAtLogin = (status == .enabled)
    }

    func start() {
        logWatcher.onSessionChanged = { [weak self] session in
            Task { @MainActor in
                self?.handleDetectedSession(session)
            }
        }
        logWatcher.onLibraryUpdated = { [weak self] games in
            Task { @MainActor in
                self?.libraryGames = games
            }
        }
        logWatcher.start()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.catalog.refreshIfNeeded()
            await MainActor.run {
                self.catalogReady = true
                self.recomputePresence()
            }
        }

        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushDesiredActivity()
            }
        }

        recomputePresence()
    }

    func stop() {
        refreshTask?.cancel()
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        logWatcher.stop()
        discordIPC.clearAndDisconnectNow()
    }

    // MARK: - Manual override

    func setManualGame(title: String, artworkURL: URL? = nil) {
        manualOverride = GameSession(title: title, artworkURL: artworkURL, startedAt: Date())
        recomputePresence()
    }

    func clearManualOverride() {
        manualOverride = nil
        recomputePresence()
    }

    // MARK: - Private

    private func handleDetectedSession(_ session: GameSession?) {
        let previousId = detectedSession?.gfnAppId ?? detectedSession?.title
        detectedSession = session

        if let session {
            let newId = session.gfnAppId ?? session.title
            if previousId != newId {
                manualOverride = nil
            }
        }

        recomputePresence()
    }

    func recomputePresence() {
        applyGeneration += 1

        guard isEnabled else {
            clearPresence()
            return
        }

        let source: PresenceSource?
        if let manual = manualOverride {
            source = .manual(title: manual.title, artworkURL: manual.artworkURL)
        } else if let detected = detectedSession {
            source = .automatic(detected)
        } else {
            source = nil
        }

        guard let source else {
            clearPresence()
            return
        }

        let generation = applyGeneration
        Task { await apply(source: source, generation: generation) }
    }

    private func clearPresence() {
        isShowingPresence = false
        desiredTarget = nil
        currentTitle = nil
        currentArtworkURL = nil
        discordStatus = .idle
        discordIPC.clearActivity()
    }

    private func apply(source: PresenceSource, generation: Int) async {
        await catalog.ensureLoaded()

        let title: String
        let executable: String?
        let artwork: URL?
        let startedAt: Date

        switch source {
        case .automatic(let session):
            title = session.title
            executable = session.executable
            artwork = session.artworkURL
            startedAt = session.startedAt
        case .manual(let manualTitle, let manualArt):
            title = manualTitle
            executable = nil
            artwork = manualArt
            startedAt = manualOverride?.startedAt ?? Date()
        }

        let match = await catalog.lookup(executable: executable, title: title)
        let target = GameResolver.resolve(
            title: title,
            executable: executable,
            artworkURL: artwork,
            startedAt: startedAt,
            fallbackClientId: fallbackClientId,
            catalogGame: match
        )

        guard isEnabled, generation == applyGeneration else { return }

        currentTitle = target.details
        currentArtworkURL = target.largeImageKey.flatMap(URL.init(string:))

        if match == nil && (fallbackClientId.isEmpty || fallbackClientId == Self.defaultFallbackClientId) {
            isShowingPresence = false
            desiredTarget = nil
            discordStatus = .needsFallbackId
            return
        }

        if desiredTarget?.clientId != target.clientId {
            discordStatus = .connecting
        }
        desiredTarget = target
        pushDesiredActivity()
    }

    private func pushDesiredActivity() {
        guard isEnabled, let target = desiredTarget else { return }

        discordIPC.setActivity(target) { [weak self] result in
            Task { @MainActor in
                self?.handleSetActivityResult(result, for: target)
            }
        }
    }

    private func handleSetActivityResult(_ result: Result<Void, DiscordIPC.IPCError>, for target: PresenceTarget) {
        guard isEnabled else {
            discordIPC.clearActivity()
            return
        }
        guard desiredTarget == target else { return }

        switch result {
        case .success:
            isShowingPresence = true
            discordStatus = .connected
        case .failure(let error):
            isShowingPresence = false
            discordStatus = .error(error.description)
        }
    }

    private func updateLoginItem() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let enabled = SMAppService.mainApp.status == .enabled
            if launchesAtLogin != enabled {
                launchesAtLogin = enabled
            }
        }
    }
}
