import Foundation

/// Deterministic, non-network fixture used by Store review and UI capture.
///
/// The fixture contains synthetic metadata only. It deliberately has no cover
/// bytes, audio bytes, tokens, cookies, or real user information. Keeping it in
/// the music module lets the SwiftUI shell expose a review path without
/// coupling the app layer to Spotify DTOs or network clients.
public enum SpotifyDemoFixture {
    public static let tracks: [SpotifyTrackReference] = [
        SpotifyTrackReference(
            id: "mediafetch-demo-track-01",
            uri: "spotify:track:mediafetch-demo-track-01",
            externalURL: nil,
            title: "Northern Lights",
            artists: ["Aria North"],
            album: "Midnight Atlas",
            discNumber: 1,
            trackNumber: 1,
            durationMS: 228_000,
            isrc: "USPRV2600001"
        ),
        SpotifyTrackReference(
            id: "mediafetch-demo-track-02",
            uri: "spotify:track:mediafetch-demo-track-02",
            externalURL: nil,
            title: String(localized: "城市边缘"),
            artists: [String(localized: "林屿"), "Mira Chen"],
            album: String(localized: "夜航"),
            discNumber: 1,
            trackNumber: 2,
            durationMS: 247_000,
            isrc: "CNPRV2600002"
        ),
        SpotifyTrackReference(
            id: "mediafetch-demo-track-03",
            uri: "spotify:track:mediafetch-demo-track-03",
            externalURL: nil,
            title: String(localized: "A Very Long Track Title for Multilingual Layout Verification — 未匹配版本"),
            artists: ["The Reference Ensemble"],
            album: "Layout Stress Test",
            discNumber: 1,
            trackNumber: 3,
            durationMS: 314_000,
            isrc: nil
        ),
        SpotifyTrackReference(
            id: "mediafetch-demo-track-04",
            uri: "spotify:track:mediafetch-demo-track-04",
            externalURL: nil,
            title: "Afterglow",
            artists: ["Glass Harbor"],
            album: "Night Drive Selects",
            discNumber: 1,
            trackNumber: 4,
            durationMS: 201_000,
            isrc: "GBPRV2600004"
        )
    ]

    public static let collection = SpotifyCollection(
        id: "37i9dQZF1DX-mediafetch-demo",
        kind: .playlist,
        uri: "spotify:playlist:37i9dQZF1DX-mediafetch-demo",
        externalURL: nil,
        title: String(localized: "夜行剪辑室 · Night Drive Selects"),
        subtitle: String(localized: "MediaFetch 演示资料 · 合成元数据，不连接 Spotify"),
        tracks: tracks
    )

    public static var emptyItems: [SpotifyBridgeItem] {
        tracks.map { SpotifyBridgeItem(track: $0) }
    }
}
