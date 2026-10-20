import Foundation

public actor LinkRunway {
    /// Sent in the user agent as `LinkRunwaySDK/<version> iOS` (or `tvOS`).
    public static let sdkVersion = "0.2.0"

    let endpoint: URL
    let key: String
    let store: Store
    let env: Environment
    var consent = false
    /// Advances on every withdrawal, so a response that started under an earlier consent is never stored.
    var epoch = 0
    var clickToken: String?
    var installIdentifier: String?
    // Actors are reentrant: concurrent callers of a once-per-install operation share one request.
    var matchFlight: Task<InstallMatch?, any Error>?
    var claimFlight: Task<AdServicesClaim?, any Error>?
    var attestFlight: Task<AttestationStatus?, Never>?
    var conversionAppId: String?
    /// The tail of the conversion queue; see `queueConversion`.
    var conversionWork: Task<ConversionUpdate?, Never>?
    var rules: CachedRules?
    var rulesRetryAfter: Date?
    var attestAppId: String?
    /// The app whose challenge was answered 409 in this process. Kept in memory only, so the next launch asks again.
    var attestDisabledApp: String?

    public init(endpoint: URL, publishableKey: String, suiteName: String = "LinkRunway") {
        self.init(endpoint: endpoint, publishableKey: publishableKey, suiteName: suiteName,
                  environment: Environment(transport: SessionTransport(session: .shared)))
    }

    /// Sends every request through `session`: your own configuration, or a `URLProtocol` stub in tests.
    public init(endpoint: URL, publishableKey: String, suiteName: String = "LinkRunway", session: URLSession) {
        self.init(endpoint: endpoint, publishableKey: publishableKey, suiteName: suiteName,
                  environment: Environment(transport: SessionTransport(session: session)))
    }

    init(endpoint: URL, publishableKey: String, suiteName: String, environment: Environment) {
        precondition(publishableKey.hasPrefix("lr_pk_"), "Only publishable keys belong in mobile apps")
        precondition(endpoint.scheme == "https" || endpoint.host == "localhost", "HTTPS is required")
        self.endpoint = endpoint
        self.key = publishableKey
        self.store = Store(defaults: environment.storage(suiteName),
                           scope: "\(endpoint.absoluteString):\(publishableKey.prefix(20))")
        self.env = environment
    }

    public func setConsent(_ value: Bool) {
        consent = value
        if value {
            clickToken = store.string(.clickToken)
            // A random UUID for this installation, created with consent. Not a device or advertising identifier.
            let id = store.string(.installId) ?? UUID().uuidString.lowercased()
            installIdentifier = id
            store.set(id, .installId)
        } else {
            epoch += 1
            clickToken = nil
            installIdentifier = nil
            rules = nil
            rulesRetryAfter = nil
            conversionWork = nil
            matchFlight = nil
            claimFlight = nil
            attestFlight = nil
            store.wipe()
        }
    }

    public func attributionToken() -> String? { consent ? clickToken : nil }

    @discardableResult
    public func open(_ url: URL) async throws -> ResolvedLink? {
        guard consent else { return nil }
        if let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "lr_token" })?.value {
            saveToken(token)
            return nil
        }
        let started = epoch
        let payload = ResolveRequest(url: url.absoluteString, consent: true, platform: Platform.resolveName)
        let result: ResolvedLink = try await post("resolve", payload)
        guard isCurrent(started) else { return nil }
        saveToken(result.clickToken)
        return result
    }

    @discardableResult
    public func track(type: String, eventId: String = UUID().uuidString,
                      userId: String? = nil, metadata: [String: String] = [:], occurredAt: Date = Date()) async throws -> TrackingResult? {
        try await send(type: type, name: nil, eventId: eventId, userId: userId, metadata: metadata, occurredAt: occurredAt)
    }

    /// `track` with the event's custom name, which conversion rules can match.
    @discardableResult
    public func track(type: String, name: String, eventId: String = UUID().uuidString,
                      userId: String? = nil, metadata: [String: String] = [:], occurredAt: Date = Date()) async throws -> TrackingResult? {
        try await send(type: type, name: name, eventId: eventId, userId: userId, metadata: metadata, occurredAt: occurredAt)
    }

    private func send(type: String, name: String?, eventId: String, userId: String?,
                      metadata: [String: String], occurredAt: Date) async throws -> TrackingResult? {
        guard consent else { return nil }
        let allowed = ["INSTALL", "OPEN", "SIGNUP", "CUSTOM"]
        guard allowed.contains(type) else { throw LinkRunwayError.invalidEvent }
        let started = epoch
        // Attestation never blocks an event: without a valid token the event is sent unattested.
        let attestation = await eventAttestation()
        guard isCurrent(started) else { return nil }
        let payload = EventRequest(eventId: eventId, type: type, name: name, clickToken: clickToken,
                                  externalUserId: userId, metadata: metadata, consent: true,
                                  occurredAt: Timestamp.string(occurredAt),
                                  installId: installIdentifier, attestation: attestation)
        let result: TrackingResult = try await post("track", payload)
        queueConversion(event: type, name: name, amount: 0, since: started)
        return result
    }

    public func createShare(linkId: String, userId: String? = nil, channel: String = "native_share") async throws -> SharedLink {
        guard consent else { throw LinkRunwayError.consentRequired }
        return try await post("shares", ShareRequest(linkId: linkId, externalUserId: userId, channel: channel))
    }

    @discardableResult
    public func install() async throws -> TrackingResult? {
        guard consent, !store.flag(.installSent) else { return nil }
        let eventId = store.string(.installEvent) ?? UUID().uuidString
        store.set(eventId, .installEvent)
        let started = epoch
        let result = try await track(type: "INSTALL", eventId: eventId)
        if result != nil && isCurrent(started) { store.mark(.installSent) }
        return result
    }

    public func createReferralCode() async throws -> ReferralCode? {
        guard consent, let token = clickToken else { throw LinkRunwayError.consentRequired }
        let started = epoch
        let result: ReferralCode = try await post("deferred", ReferralCreateRequest(clickToken: token, consent: true))
        return isCurrent(started) ? result : nil
    }

    public func claimReferralCode(_ code: String, claimId: UUID) async throws -> ResolvedLink? {
        guard consent else { return nil }
        let started = epoch
        let result: ResolvedLink = try await post("deferred/claim", ReferralClaimRequest(code: code, claimId: claimId.uuidString, consent: true))
        guard isCurrent(started) else { return nil }
        saveToken(result.clickToken)
        return result
    }

    func saveToken(_ token: String?) {
        guard consent else { return }
        clickToken = token
        store.set(token, .clickToken)
    }
}
