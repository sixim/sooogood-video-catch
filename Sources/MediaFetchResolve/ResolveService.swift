import Combine
import Foundation
import MediaFetchCore

#if !MEDIAFETCH_STORE_PROFILE
/// UI façade for "Send to DaVinci Resolve". Every successful send is appended
/// to `resolve-imports.json` inside the package, next to its manifest.
@MainActor
public final class ResolveService: ObservableObject {
    public enum Connection: Equatable {
        case unknown
        case checking
        case connected(ResolveStatus)
        case failed(String, canLaunch: Bool)
    }

    @Published public private(set) var connection: Connection = .unknown
    @Published public private(set) var sendingPackages: Set<String> = []
    @Published public private(set) var lastResults: [String: ResolveImportResult] = [:]
    @Published public var errorMessage: String?

    private let bridgeFactory: () throws -> ResolveBridge

    public init(bridgeFactory: (() throws -> ResolveBridge)? = nil) {
        self.bridgeFactory = bridgeFactory ?? { ResolveBridge(environment: try .discover()) }
    }

    public var isInstalled: Bool { (try? ResolveBridge.Environment.discover()) != nil }

    public func refreshStatus() async {
        connection = .checking
        do {
            connection = .connected(try await bridgeFactory().status())
        } catch {
            connection = Self.failure(error)
        }
    }

    public func launchResolve() async {
        connection = .checking
        do {
            connection = .connected(try await bridgeFactory().launchAndWait())
        } catch {
            connection = Self.failure(error)
        }
    }

    /// Imports one package folder into the current Resolve project.
    @discardableResult
    public func send(packageDirectory: URL, proxies: [String: String] = [:], timelineName: String? = nil) async -> ResolveImportResult? {
        await perform(key: packageDirectory.path, logDirectory: packageDirectory) {
            try ResolveImportPlanner.plan(packageDirectory: packageDirectory, proxies: proxies, timelineName: timelineName)
        }
    }

    /// Imports specific files (e.g. a single-file torrent) under a named bin.
    @discardableResult
    public func send(files: [URL], binName: String, manifestURL: URL?, key: String) async -> ResolveImportResult? {
        await perform(key: key, logDirectory: nil) {
            ResolveImportPlanner.plan(
                files: files, binName: binName,
                provenance: manifestURL.flatMap(ResolveImportPlanner.Provenance.load(from:))
            )
        }
    }

    private func perform(
        key: String,
        logDirectory: URL?,
        makeRequest: () throws -> ResolveImportRequest
    ) async -> ResolveImportResult? {
        guard !sendingPackages.contains(key) else { return nil }
        sendingPackages.insert(key)
        defer { sendingPackages.remove(key) }
        errorMessage = nil
        do {
            let request = try makeRequest()
            guard !request.isEmpty else {
                errorMessage = "没有可导入达芬奇的媒体文件"
                return nil
            }
            let result = try await bridgeFactory().importMedia(request)
            lastResults[key] = result
            connection = .connected(ResolveStatus(product: result.product, version: result.version, project: result.project))
            if let logDirectory { try? ResolveImportLog.append(result, to: logDirectory) }
            if !result.failed.isEmpty {
                errorMessage = "有 \(result.failed.count) 个文件达芬奇没有接受：" + result.failed.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            }
            return result
        } catch {
            connection = Self.failure(error)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    static func failure(_ error: Error) -> Connection {
        let bridgeError = error as? ResolveBridgeError
        return .failed(error.localizedDescription, canLaunch: bridgeError?.suggestsLaunching == true)
    }
}

/// Append-only record of Resolve imports kept inside each package.
public enum ResolveImportLog {
    public static let fileName = "resolve-imports.json"

    struct Entry: Codable {
        let importedAt: Date
        let product: String
        let version: String
        let project: String
        let bin: [String]
        let clips: [String]
        let subtitles: [String]
        let failed: [String]
        let timeline: String?
    }

    public static func append(_ result: ResolveImportResult, to directory: URL) throws {
        let url = directory.appendingPathComponent(fileName)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries = (try? decoder.decode([Entry].self, from: Data(contentsOf: url))) ?? []
        entries.append(Entry(
            importedAt: Date(), product: result.product, version: result.version, project: result.project,
            bin: result.bin, clips: result.clips.map { ($0.path as NSString).lastPathComponent },
            subtitles: result.subtitles.map { ($0 as NSString).lastPathComponent },
            failed: result.failed.map { ($0 as NSString).lastPathComponent }, timeline: result.timeline
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}
#endif
