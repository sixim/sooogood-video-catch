import Foundation

public struct SpotifyMatcher: Sendable {
    public let automaticMatchMinimumScore: Int
    public let automaticMatchMinimumLead: Int

    public init(automaticMatchMinimumScore: Int = 95, automaticMatchMinimumLead: Int = 10) {
        self.automaticMatchMinimumScore = automaticMatchMinimumScore
        self.automaticMatchMinimumLead = automaticMatchMinimumLead
    }

    public func match(
        tracks: [SpotifyTrackReference],
        candidates: [LocalAudioCandidate]
    ) -> [SpotifyBridgeItem] {
        tracks.map { match(track: $0, candidates: candidates) }
    }

    public func match(
        track: SpotifyTrackReference,
        candidates: [LocalAudioCandidate]
    ) -> SpotifyBridgeItem {
        let matches = candidates.compactMap { candidate -> SpotifyCandidateMatch? in
            guard let evidence = evidence(for: track, candidate: candidate) else { return nil }
            return SpotifyCandidateMatch(candidate: candidate, evidence: evidence)
        }.sorted {
            if $0.evidence.score != $1.evidence.score {
                return $0.evidence.score > $1.evidence.score
            }
            return $0.candidate.url.path.localizedStandardCompare($1.candidate.url.path) == .orderedAscending
        }

        guard let best = matches.first else {
            return SpotifyBridgeItem(track: track, status: .unmatched)
        }

        let secondScore = matches.dropFirst().first?.evidence.score
        let hasRequiredLead = secondScore.map {
            best.evidence.score - $0 >= automaticMatchMinimumLead
        } ?? true
        let canAutomaticallySelect = best.evidence.score >= automaticMatchMinimumScore &&
            best.evidence.isAutomaticallyEligible && hasRequiredLead

        if canAutomaticallySelect {
            return SpotifyBridgeItem(
                track: track,
                matches: matches,
                source: .localFile(best.candidate.url),
                evidence: best.evidence,
                status: .ready
            )
        }
        return SpotifyBridgeItem(
            track: track,
            matches: matches,
            evidence: best.evidence,
            status: .ambiguous
        )
    }

    public func evidence(
        for track: SpotifyTrackReference,
        candidate: LocalAudioCandidate
    ) -> MatchEvidence? {
        let trackISRC = normalizedISRC(track.isrc)
        let candidateISRC = normalizedISRC(candidate.isrc)
        let artistsMatch = artistKey(track.artists) == artistKey(candidate.artists) &&
            !artistKey(track.artists).isEmpty
        let exactTitleMatch = normalized(track.title) == normalized(candidate.title)
        let baseTitleMatch = baseTitle(track.title) == baseTitle(candidate.title) &&
            !baseTitle(track.title).isEmpty
        let titleVersionConflict = baseTitleMatch && !exactTitleMatch &&
            versionTags(track.title) != versionTags(candidate.title)
        let albumBaseMatch = track.album.map(baseTitle) == candidate.album.map(baseTitle) &&
            track.album.map(baseTitle).map { !$0.isEmpty } == true
        let albumVersionConflict = albumBaseMatch &&
            versionTags(track.album ?? "") != versionTags(candidate.album ?? "")
        let explicitConflict = track.isExplicit != nil && candidate.isExplicit != nil &&
            track.isExplicit != candidate.isExplicit
        let explicitEvidenceIncomplete = track.isExplicit != nil && candidate.isExplicit == nil
        let versionConflict = titleVersionConflict || albumVersionConflict || explicitConflict
        let durationDifference = candidate.durationMS.map { abs($0 - track.durationMS) }
        let durationMatches = durationDifference.map { $0 <= 2_000 } == true
        let albumsMatch = normalizedOptional(track.album) != nil &&
            normalizedOptional(track.album) == normalizedOptional(candidate.album)

        if let trackISRC, let candidateISRC, trackISRC == candidateISRC {
            if versionConflict {
                return MatchEvidence(
                    score: 85,
                    matchedFields: [.isrc],
                    reasons: ["ISRC 一致，但检测到 Live、Remaster、Explicit、Clean、Deluxe 等版本证据冲突，必须人工确认"],
                    versionConflict: true
                )
            }
            return MatchEvidence(
                score: 100,
                matchedFields: [.isrc],
                reasons: ["ISRC 完全一致"]
            )
        }

        if artistsMatch && (exactTitleMatch || baseTitleMatch) && versionConflict {
            return MatchEvidence(
                score: 85,
                matchedFields: [.artist, .title] + (durationMatches ? [.duration] : []),
                reasons: ["检测到 Live、Remaster、Explicit、Clean、Deluxe 等版本证据冲突，必须人工确认"],
                versionConflict: true
            )
        }

        if artistsMatch && exactTitleMatch && durationMatches && !candidate.titleWasFilenameFallback {
            if albumsMatch {
                if explicitEvidenceIncomplete {
                    return MatchEvidence(
                        score: 90,
                        matchedFields: [.artist, .title, .album, .duration],
                        reasons: ["歌手、标题、专辑和时长一致，但本地文件缺少 Explicit/Clean 版本证据，必须人工确认"]
                    )
                }
                return MatchEvidence(
                    score: 95,
                    matchedFields: [.artist, .title, .album, .duration],
                    reasons: ["歌手、标题、专辑一致，时长误差不超过 2 秒"]
                )
            }
            return MatchEvidence(
                score: 90,
                matchedFields: [.artist, .title, .duration],
                reasons: ["歌手、标题一致，时长误差不超过 2 秒"]
            )
        }

        if artistsMatch && exactTitleMatch {
            var reasons = ["歌手和标题一致，但缺少可靠的时长或专辑证据"]
            if let durationDifference, durationDifference > 2_000 {
                reasons = ["歌手和标题一致，但时长相差超过 2 秒，必须人工确认"]
            }
            var fields: [SpotifyMatchField] = [.artist, .title]
            if albumsMatch { fields.append(.album) }
            if candidate.titleWasFilenameFallback { fields.append(.filenameFallback) }
            return MatchEvidence(
                score: 85,
                matchedFields: fields,
                reasons: reasons
            )
        }

        if candidate.titleWasFilenameFallback && filenameSuggests(track: track, filenameStem: candidate.title) {
            var fields: [SpotifyMatchField] = [.filenameFallback]
            if artistsMatch { fields.append(.artist) }
            if durationMatches { fields.append(.duration) }
            return MatchEvidence(
                score: artistsMatch && durationMatches ? 85 : 80,
                matchedFields: fields,
                reasons: ["仅文件名看起来相符，不能自动匹配"]
            )
        }

        if baseTitleMatch && artistsMatch {
            return MatchEvidence(
                score: 80,
                matchedFields: [.artist, .title],
                reasons: ["歌手和标题主体相似，证据不足，必须人工确认"],
                versionConflict: versionConflict
            )
        }
        return nil
    }

    private func normalizedISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return compact.isEmpty ? nil : compact
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }

    private func artistKey(_ artists: [String]) -> String {
        artists
            .map(normalized)
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: "|")
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func baseTitle(_ title: String) -> String {
        let tokenPattern = versionTokenPattern
        var base = title.replacingOccurrences(
            of: #"\s*[\(\[\{][^\)\]\}]*\b("# + tokenPattern + #")\b[^\)\]\}]*[\)\]\}]\s*"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        base = base.replacingOccurrences(
            of: #"\s*[-–—]\s*[^-–—]*\b("# + tokenPattern + #")\b[^-–—]*$"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        return normalized(base)
    }

    private func versionTags(_ title: String) -> Set<String> {
        let normalizedTitle = normalized(title)
        return Set(versionTokens.filter { token in
            normalizedTitle.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: token) + #"\b"#, options: .regularExpression) != nil
        })
    }

    private func filenameSuggests(track: SpotifyTrackReference, filenameStem: String) -> Bool {
        let filename = normalized(filenameStem)
        let title = normalized(track.title)
        if filename == title { return true }
        return track.artists.contains { artist in
            let artistName = normalized(artist)
            return filename == "\(artistName) \(title)" || filename == "\(title) \(artistName)"
        }
    }

    private var versionTokens: [String] {
        [
            "live", "remaster", "remastered", "explicit", "clean", "deluxe",
            "acoustic", "instrumental", "mono", "stereo", "radio edit", "edit",
            "version", "remix"
        ]
    }

    private var versionTokenPattern: String {
        versionTokens.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }
}
