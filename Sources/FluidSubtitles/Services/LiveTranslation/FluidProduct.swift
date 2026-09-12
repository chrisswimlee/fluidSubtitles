import Foundation

/// User-facing identity for fluidSubtitles.
enum FluidProduct {
    static let displayName = "fluidSubtitles"
    static let shortName = "Subtitles"
    static let bundleIdentifier = "com.fluidsubtitles.app"
    static let tagline = "Captions after each sentence. Korean, English, and Thai."
    static let manifesto = "Language is no longer a barrier."

    static let supportFolderName = "fluidSubtitles"
    static let priorSupportFolderNames = ["connectingCaptions", "FluidVoice"]
    static let legacySupportFolderName = "FluidVoice"
    static let keychainService = "com.fluidsubtitles.provider-api-keys"
    static let legacyKeychainService = "com.fluidvoice.provider-api-keys"
    static let keychainAccount = "fluidSubtitlesApiKeys"
    static let legacyKeychainAccount = "fluidApiKeys"
    static let priorKeychainIdentities: [(service: String, account: String)] = [
        ("com.connectingcaptions.provider-api-keys", "connectingCaptionsApiKeys"),
        ("com.fluidvoice.provider-api-keys", "fluidApiKeys"),
    ]

    static var keychainLookupIdentities: [(service: String, account: String)] {
        [(self.keychainService, self.keychainAccount)] + self.priorKeychainIdentities
    }

    static let githubOwner: String? = "chrisswimlee"
    static let githubRepo: String? = "fluidSubtitles"
    static let helpURL = URL(string: "https://github.com/chrisswimlee/fluidSubtitles/issues/new/choose")
    static let feedbackURL = URL(string: "https://github.com/chrisswimlee/fluidSubtitles/issues/new?labels=bug")
    static let examplesURL = URL(string: "https://github.com/chrisswimlee/fluidSubtitles#theater-captions")

    static let authorName = "Chris Swim Lee"
    static let authorSiteHost = "chrisswimlee.com"
    static let authorURL = URL(string: "https://chrisswimlee.com")!

    static let upstreamName = "FluidVoice"
    static let upstreamAuthor = "altic-dev"
    static let upstreamURL = URL(string: "https://github.com/altic-dev/FluidVoice")!

    static let creditLine =
        "fluidSubtitles is by Chris Swim Lee (chrisswimlee.com), a branch of FluidVoice by altic-dev. Speech recognition and the core app are theirs; live translation and Theater are what we added. Licensed under GPLv3."

    static let creditShort =
        "By Chris Swim Lee. A branch of FluidVoice by altic-dev. GPLv3."

    static var updateRepository: (owner: String, repo: String)? {
        guard let owner = self.githubOwner, let repo = self.githubRepo,
              !owner.isEmpty, !repo.isEmpty
        else {
            return nil
        }
        return (owner, repo)
    }

    static var releasesURL: URL? {
        guard let repository = self.updateRepository else { return nil }
        return URL(string: "https://github.com/\(repository.owner)/\(repository.repo)/releases")
    }

    static var issuesURL: URL? {
        guard let repository = self.updateRepository else { return nil }
        return URL(string: "https://github.com/\(repository.owner)/\(repository.repo)/issues/new/choose")
    }

    /// Developer ID team IDs allowed to install updates, in addition to the running app’s team.
    /// Keep this empty until a published Developer ID identity is known; empty and ad-hoc teams are rejected.
    static let allowedUpdateTeamIDs: Set<String> = []
}
