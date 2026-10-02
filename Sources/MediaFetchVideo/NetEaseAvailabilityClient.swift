import Foundation
import MediaFetchCore

/// Asks NetEase which listed tracks it can serve at all (see `NetEaseAvailability`).
/// Best effort: on any failure it returns what it has, and callers treat
/// unknown tracks as available — the download itself still reports the truth.
struct NetEaseAvailabilityClient: Sendable {
    var session: URLSession = .shared

    func statuses(for ids: [String]) async -> [String: NetEaseAvailability.Status] {
        var result: [String: NetEaseAvailability.Status] = [:]
        let unique = Array(Set(ids.filter { Int($0) != nil })).sorted()
        for start in stride(from: 0, to: unique.count, by: NetEaseAvailability.batchSize) {
            let batch = Array(unique[start..<min(start + NetEaseAvailability.batchSize, unique.count)])
            guard let url = NetEaseAvailability.detailURL(ids: batch) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            result.merge(NetEaseAvailability.parse(data)) { $1 }
        }
        return result
    }
}
