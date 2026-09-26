import Foundation

public enum SpotifyResourceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case track
    case album
    case playlist

    public var id: String { rawValue }
}

public struct SpotifyTrackReference: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let uri: String
    public let externalURL: URL?
    public let title: String
    public let artists: [String]
    public let album: String?
    public let discNumber: Int
    public let trackNumber: Int
    public let durationMS: Int
    public let isExplicit: Bool?
    public let isrc: String?

    public init(
        id: String,
        uri: String,
        externalURL: URL?,
        title: String,
        artists: [String],
        album: String?,
        discNumber: Int,
        trackNumber: Int,
        durationMS: Int,
        isExplicit: Bool? = nil,
        isrc: String?
    ) {
        self.id = id
        self.uri = uri
        self.externalURL = externalURL
        self.title = title
        self.artists = artists
        self.album = album
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.durationMS = durationMS
        self.isExplicit = isExplicit
        self.isrc = isrc
    }
}

public struct SpotifyCollection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: SpotifyResourceKind
    public let uri: String
    public let externalURL: URL?
    public let title: String
    public let subtitle: String?
    public let coverURL: URL?
    public let tracks: [SpotifyTrackReference]

    public init(
        id: String,
        kind: SpotifyResourceKind,
        uri: String,
        externalURL: URL?,
        title: String,
        subtitle: String? = nil,
        coverURL: URL? = nil,
        tracks: [SpotifyTrackReference]
    ) {
        self.id = id
        self.kind = kind
        self.uri = uri
        self.externalURL = externalURL
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.tracks = tracks
    }
}

public struct LocalAudioCandidate: Codable, Hashable, Identifiable, Sendable {
    public let url: URL
    public let title: String
    public let artists: [String]
    public let album: String?
    public let durationMS: Int?
    public let isrc: String?
    public let isExplicit: Bool?
    public let discNumber: Int?
    public let trackNumber: Int?
    public let codec: String?
    public let byteSize: Int64
    public let titleWasFilenameFallback: Bool
    public let probeWarning: String?

    public var id: String { url.standardizedFileURL.path }

    public init(
        url: URL,
        title: String,
        artists: [String] = [],
        album: String? = nil,
        durationMS: Int? = nil,
        isrc: String? = nil,
        isExplicit: Bool? = nil,
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        codec: String? = nil,
        byteSize: Int64 = 0,
        titleWasFilenameFallback: Bool = false,
        probeWarning: String? = nil
    ) {
        self.url = url
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMS = durationMS
        self.isrc = isrc
        self.isExplicit = isExplicit
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.codec = codec
        self.byteSize = byteSize
        self.titleWasFilenameFallback = titleWasFilenameFallback
        self.probeWarning = probeWarning
    }
}

public enum SpotifyMatchField: String, Codable, Hashable, Sendable {
    case isrc
    case artist
    case title
    case album
    case duration
    case filenameFallback
}

public struct MatchEvidence: Codable, Hashable, Sendable {
    public let score: Int
    public let matchedFields: [SpotifyMatchField]
    public let reasons: [String]
    public let versionConflict: Bool
    public var userConfirmed: Bool

    public var isAutomaticallyEligible: Bool {
        score >= 95 && !versionConflict && !matchedFields.contains(.filenameFallback)
    }

    public init(
        score: Int,
        matchedFields: [SpotifyMatchField],
        reasons: [String] = [],
        versionConflict: Bool = false,
        userConfirmed: Bool = false
    ) {
        self.score = score
        self.matchedFields = matchedFields
        self.reasons = reasons
        self.versionConflict = versionConflict
        self.userConfirmed = userConfirmed
    }
}

public enum AudioSource: Codable, Hashable, Sendable {
    case localFile(URL)
    case authorizedDirectURL(URL)

    private enum CodingKeys: String, CodingKey {
        case type
        case url
    }

    private enum SourceType: String, Codable {
        case localFile
        case authorizedDirectURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SourceType.self, forKey: .type)
        let url = try container.decode(URL.self, forKey: .url)
        switch type {
        case .localFile:
            self = .localFile(url)
        case .authorizedDirectURL:
            self = .authorizedDirectURL(url)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localFile(let url):
            try container.encode(SourceType.localFile, forKey: .type)
            try container.encode(url, forKey: .url)
        case .authorizedDirectURL(let url):
            try container.encode(SourceType.authorizedDirectURL, forKey: .type)
            try container.encode(url, forKey: .url)
        }
    }

    public var typeDescription: String {
        switch self {
        case .localFile: return "localFile"
        case .authorizedDirectURL: return "authorizedDirectURL"
        }
    }
}

public struct SpotifyCandidateMatch: Codable, Hashable, Identifiable, Sendable {
    public let candidate: LocalAudioCandidate
    public let evidence: MatchEvidence

    public init(candidate: LocalAudioCandidate, evidence: MatchEvidence) {
        self.candidate = candidate
        self.evidence = evidence
    }

    public var id: String { candidate.id }
}

public enum SpotifyBridgeItemStatus: String, Codable, CaseIterable, Sendable {
    case unmatched
    case ambiguous
    case ready
    case copying
    case completed
    case failed
}

public struct SpotifyBridgeItem: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let track: SpotifyTrackReference
    public var matches: [SpotifyCandidateMatch]
    public var source: AudioSource?
    public var evidence: MatchEvidence?
    public var status: SpotifyBridgeItemStatus
    public var outputRelativePath: String?
    public var sourceSHA256: String?
    public var outputSHA256: String?
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        track: SpotifyTrackReference,
        matches: [SpotifyCandidateMatch] = [],
        source: AudioSource? = nil,
        evidence: MatchEvidence? = nil,
        status: SpotifyBridgeItemStatus = .unmatched,
        outputRelativePath: String? = nil,
        sourceSHA256: String? = nil,
        outputSHA256: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.track = track
        self.matches = matches
        self.source = source
        self.evidence = evidence
        self.status = status
        self.outputRelativePath = outputRelativePath
        self.sourceSHA256 = sourceSHA256
        self.outputSHA256 = outputSHA256
        self.failureReason = failureReason
    }

    public mutating func confirm(candidate: LocalAudioCandidate) {
        source = .localFile(candidate.url)
        if var selectedEvidence = matches.first(where: { $0.candidate.id == candidate.id })?.evidence {
            selectedEvidence.userConfirmed = true
            evidence = selectedEvidence
        } else {
            evidence = MatchEvidence(
                score: 0,
                matchedFields: [],
                reasons: ["用户手动选择本地音频"],
                userConfirmed: true
            )
        }
        status = .ready
        failureReason = nil
    }

    public mutating func confirm(source newSource: AudioSource) {
        source = newSource
        evidence = MatchEvidence(
            score: 0,
            matchedFields: [],
            reasons: ["用户手动授权音频来源"],
            userConfirmed: true
        )
        status = .ready
        failureReason = nil
    }
}

public struct SpotifyBridgeManifestV2: Codable, Sendable {
    public struct CollectionRecord: Codable, Sendable {
        public let id: String
        public let kind: SpotifyResourceKind
        public let uri: String
        public let externalURL: URL?
        public let title: String
    }

    public struct ItemRecord: Codable, Sendable {
        public let itemID: UUID
        public let spotifyTrackID: String
        public let spotifyURI: String
        public let spotifyURL: URL?
        public let title: String
        public let artists: [String]
        public let album: String?
        public let sourceType: String?
        public let sourceFileName: String?
        public let outputRelativePath: String?
        public let byteSize: Int64?
        public let sourceSHA256: String?
        public let outputSHA256: String?
        public let matchEvidence: MatchEvidence?
        public let status: SpotifyBridgeItemStatus
        public let failureReason: String?
    }

    public let schemaVersion: Int
    public let createdAt: Date
    public let collection: CollectionRecord
    public let items: [ItemRecord]
}

public struct SpotifyBridgeSaveResult: Sendable {
    public let packageDirectory: URL
    public let playlistURL: URL
    public let manifestURL: URL
    public let items: [SpotifyBridgeItem]

    public var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }
}
