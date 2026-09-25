import Foundation

struct GameSession: Equatable, Sendable {
    var title: String
    var gfnAppId: String?
    var executable: String?
    var shortName: String?
    var artworkURL: URL?
    var startedAt: Date

    init(
        title: String,
        gfnAppId: String? = nil,
        executable: String? = nil,
        shortName: String? = nil,
        artworkURL: URL? = nil,
        startedAt: Date = Date()
    ) {
        self.title = title
        self.gfnAppId = gfnAppId
        self.executable = executable
        self.shortName = shortName
        self.artworkURL = artworkURL
        self.startedAt = startedAt
    }
}

struct PresenceTarget: Equatable, Sendable {
    var clientId: String
    var details: String
    var state: String?
    var largeImageKey: String?
    var largeImageText: String?
    var smallImageKey: String?
    var smallImageText: String?
    var startedAt: Date
    var useStatusDisplayTypeName: Bool

    init(
        clientId: String,
        details: String,
        state: String? = nil,
        largeImageKey: String? = nil,
        largeImageText: String? = nil,
        smallImageKey: String? = nil,
        smallImageText: String? = nil,
        startedAt: Date = Date(),
        useStatusDisplayTypeName: Bool = false
    ) {
        self.clientId = clientId
        self.details = details
        self.state = state
        self.largeImageKey = largeImageKey
        self.largeImageText = largeImageText
        self.smallImageKey = smallImageKey
        self.smallImageText = smallImageText
        self.startedAt = startedAt
        self.useStatusDisplayTypeName = useStatusDisplayTypeName
    }
}

enum PresenceSource: Equatable, Sendable {
    case automatic(GameSession)
    case manual(title: String, artworkURL: URL?)
}

extension String {
    /// Normalize game titles for fuzzy matching against Discord's detectable list.
    func normalizedGameName() -> String {
        var s = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "©", with: "")
            .lowercased()

        // Map trailing / whole-token roman numerals to arabic ("Baldur's Gate III" → "... 3")
        let romanTokens = [
            "xviii": "18", "xvii": "17", "xvi": "16", "xv": "15",
            "xiv": "14", "xiii": "13", "xii": "12", "xi": "11",
            "viii": "8", "vii": "7", "vi": "6", "iv": "4",
            "iii": "3", "ii": "2"
        ]
        for (roman, arabic) in romanTokens.sorted(by: { $0.key.count > $1.key.count }) {
            s = s.replacingOccurrences(
                of: "\\b\(roman)\\b",
                with: arabic,
                options: .regularExpression
            )
        }

        return s.replacingOccurrences(
            of: "[^a-zA-Z0-9]+",
            with: "",
            options: .regularExpression
        )
    }
}
