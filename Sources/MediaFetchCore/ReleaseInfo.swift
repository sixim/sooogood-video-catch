import Foundation

/// Single source of truth for the app and provenance manifests.
///
/// Keeping release metadata in the Core module prevents the UI, package script,
/// and generated manifests from drifting during future upgrades.
public enum MediaFetchRelease {
    /// Public-facing product name. Internal module and bundle identifiers stay
    /// stable so an installed MediaFetch build continues to receive updates.
    public static let displayName = "Sooogood Video Catch"
    public static let shortDisplayName = "Sooogood"
    /// Single source for the app bundle ID and namespaced local services.
    /// Change this together with the Apple Developer/App Store record; the
    /// Store preflight blocks partial identifier updates.
    public static let bundleIdentifier = "com.simon.mediafetch"
    public static let version = "0.13.0"
    public static let build = "17"
    public static let videoManifestSchema = 2
    public static let musicManifestSchema = 2
}
