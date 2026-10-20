import Foundation

/// The answer to a first-launch match. `matched` is false when the server credited no earlier click or impression.
public struct InstallMatch: Codable, Sendable, Equatable {
    public enum Method: String, Codable, Sendable {
        // `unmatched` rather than `none`, which Swift would confuse with an absent optional.
        case referrer = "REFERRER", probabilistic = "PROBABILISTIC", viewThrough = "VIEW_THROUGH", unmatched = "NONE"
        /// A method added by a server newer than this SDK.
        case unknown = "UNKNOWN"

        public init(from decoder: any Decoder) throws {
            self = Method(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public let matched: Bool
    public let method: Method
    public let clickId: String?
    /// The link's in-app path. Route it through your own allowlist.
    public let path: String?
    public let url: String?
    public let metadata: [String: MetadataValue]

    static let unmatched = InstallMatch(matched: false, method: .unmatched, clickId: nil, path: nil, url: nil, metadata: [:])
}

extension InstallMatch {
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        matched = try values.decode(Bool.self, forKey: .matched)
        method = try values.decodeIfPresent(Method.self, forKey: .method) ?? .unmatched
        clickId = try values.decodeIfPresent(String.self, forKey: .clickId)
        path = try values.decodeIfPresent(String.self, forKey: .path)
        url = try values.decodeIfPresent(String.self, forKey: .url)
        metadata = try values.decodeIfPresent([String: MetadataValue].self, forKey: .metadata) ?? [:]
    }
}

struct InstallMatchRequest: Encodable, Sendable {
    let installId: String
    let platform: String
    let osVersion: String?
    let language: String?
    let consent: Bool
}

/// The signed click token travels with the match response but is kept out of the public result and its cache.
private struct MatchToken: Decodable {
    let clickToken: String?
}

extension LinkRunway {
    /// The random per-install UUID sent with events and match requests; nil without consent.
    /// It is created by the SDK, lives only in its `UserDefaults` suite, and is not a device or advertising identifier.
    public func installId() -> String? { consent ? installIdentifier : nil }

    /// Asks the server, once per installation, whether this first launch follows an earlier click or impression.
    /// On a match the click token is saved as `open(_:)` does. Later calls return the stored answer without a request.
    @discardableResult
    public func matchInstall() async throws -> InstallMatch? {
        guard consent, let installId = installIdentifier else { return nil }
        if let cached = store.value(.match, as: InstallMatch.self) { return cached }
        // Resolved under an earlier consent: this installation's first launch is not matched a second time.
        if store.flag(.matchResolved) { return .unmatched }
        if let running = matchFlight { return try await running.value }
        let task = Task { try await self.resolveInstall(installId) }
        matchFlight = task
        defer { if matchFlight == task { matchFlight = nil } }
        return try await task.value
    }

    private func resolveInstall(_ installId: String) async throws -> InstallMatch? {
        let started = epoch
        let request = InstallMatchRequest(installId: installId, platform: Platform.name, osVersion: env.osVersion,
                                          language: env.language, consent: true)
        let (data, _) = try await call("POST", "installs/match", body: try JSONEncoder().encode(request))
        let match = try JSONDecoder().decode(InstallMatch.self, from: data)
        guard isCurrent(started) else { return nil }
        if match.matched, let token = try? JSONDecoder().decode(MatchToken.self, from: data).clickToken { saveToken(token) }
        store.save(match, .match)
        store.mark(.matchResolved)
        return match
    }
}
