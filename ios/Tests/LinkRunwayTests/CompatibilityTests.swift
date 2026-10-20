import Foundation
import Testing
// Not `@testable`: this file sees exactly what an app sees, over a real `URLSession` and real `UserDefaults`.
import LinkRunway

/// Answers every request made through a `URLSession` configured with it, and records what was sent.
final class LoopbackProtocol: URLProtocol {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(request: URLRequest, body: Data)] = []

        func add(_ request: URLRequest, _ body: Data) {
            lock.lock()
            entries.append((request, body))
            lock.unlock()
        }

        /// Requests made with one publishable key, so tests running side by side do not see each other's.
        func sent(with key: String, to path: String) -> [(request: URLRequest, body: Data)] {
            lock.lock()
            defer { lock.unlock() }
            return entries.filter {
                $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" && $0.request.url?.path == path
            }
        }
    }

    static let log = Log()
    static let replies = [
        "/v1/track": #"{"id":"evt_session","attributed":false,"duplicate":false}"#,
        "/v1/installs/match": #"{"matched":true,"method":"REFERRER","clickId":"clk_1","clickToken":"tok_loopback","path":"/welcome","url":"https://example.com/welcome","metadata":{"campaign":"spring"}}"#,
    ]

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopbackProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLSession hands a protocol the body as a stream.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        Self.log.add(request, body)
        let reply = Self.replies[request.url?.path ?? ""]
        let response = HTTPURLResponse(url: request.url!, statusCode: reply == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((reply ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct CompatibilityTests {
    static let endpoint = URL(string: "https://sdk.linkrunway.invalid")!

    /// Every call an app written against SDK 0.1 could make, spelled as it was then.
    @Test func theOriginalApiStillCompilesAndIsStillConsentGated() async throws {
        let suite = RealSuite()
        defer { suite.remove() }
        _ = LinkRunway(endpoint: Self.endpoint, publishableKey: "lr_pk_original")
        let runway = LinkRunway(endpoint: Self.endpoint, publishableKey: "lr_pk_original", suiteName: suite.name)

        // Consent is off, so none of these reaches the network.
        await runway.setConsent(false)
        let token: String? = await runway.attributionToken()
        #expect(token == nil)
        let link: ResolvedLink? = try await runway.open(URL(string: "https://sdk.linkrunway.invalid/l/abc")!)
        #expect(link == nil)
        try await runway.open(URL(string: "https://sdk.linkrunway.invalid/l/abc")!)
        let plain: TrackingResult? = try await runway.track(type: "OPEN")
        #expect(plain == nil)
        let full: TrackingResult? = try await runway.track(type: "CUSTOM", eventId: "evt-1", userId: "user-1",
                                                           metadata: ["plan": "pro"], occurredAt: Date())
        #expect(full == nil)
        try await runway.track(type: "SIGNUP", userId: "user-1")
        let installed: TrackingResult? = try await runway.install()
        #expect(installed == nil)
        let claimed: ResolvedLink? = try await runway.claimReferralCode("ABCDEFGHJKLM", claimId: UUID())
        #expect(claimed == nil)
        await #expect(throws: LinkRunwayError.self) {
            let share: SharedLink = try await runway.createShare(linkId: "lnk_1", userId: "user-1", channel: "native_share")
            _ = share.url
        }
        await #expect(throws: LinkRunwayError.self) { _ = try await runway.createShare(linkId: "lnk_1") }
        await #expect(throws: LinkRunwayError.self) {
            let code: ReferralCode? = try await runway.createReferralCode()
            _ = code?.code
        }
        #expect(suite.contents.isEmpty)
    }

    @Test func theErrorCasesAreUnchanged() {
        func describe(_ error: LinkRunwayError) -> String {
            // Exhaustive without a default: a new case would stop apps that switch like this from compiling.
            switch error {
            case .consentRequired: return "consent"
            case .invalidEvent: return "event"
            case .invalidResponse: return "response"
            case .server(let status, let message): return "\(status) \(message)"
            }
        }
        #expect(describe(.server(402, "limit")) == "402 limit")
        #expect(describe(.consentRequired) == "consent")
    }

    @Test func requestsGoThroughAnInjectedSession() async throws {
        let suite = RealSuite()
        defer { suite.remove() }
        let session = LoopbackProtocol.session()
        defer { session.invalidateAndCancel() }
        let key = "lr_pk_session_\(UUID().uuidString.prefix(8))"
        let runway = LinkRunway(endpoint: Self.endpoint, publishableKey: key, suiteName: suite.name, session: session)
        await runway.setConsent(true)

        let result = try await runway.track(type: "CUSTOM", name: "level_10", eventId: "evt-session")
        #expect(result?.id == "evt_session")
        #expect(result?.duplicate == false)

        let mine = LoopbackProtocol.log.sent(with: key, to: "/v1/track")
        let sent = try #require(mine.first)
        #expect(mine.count == 1)
        #expect(sent.request.url?.absoluteString == "https://sdk.linkrunway.invalid/v1/track")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("LinkRunwaySDK/\(LinkRunway.sdkVersion) ") == true)
        let body = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect(body["eventId"] as? String == "evt-session")
        #expect(body["name"] as? String == "level_10")
        #expect(body["installId"] as? String == (await runway.installId()))
    }

    /// The whole path an app uses: public initializer, `URLSession`, and a `UserDefaults` suite on disk.
    @Test func anUpgradedAppKeepsItsStateInUserDefaultsAndGivesItUpOnWithdrawal() async throws {
        let suite = RealSuite()
        defer { suite.remove() }
        let session = LoopbackProtocol.session()
        defer { session.invalidateAndCancel() }
        let key = "lr_pk_real_\(UUID().uuidString.prefix(8))"
        let scope = "\(Self.endpoint.absoluteString):\(key.prefix(20))"
        // What SDK 0.1 left behind, written with the calls it used.
        suite.defaults.set("tok_legacy", forKey: "clickToken:\(scope)")
        suite.defaults.set("legacy-install-event", forKey: "install:clickToken:\(scope)")
        suite.defaults.set(true, forKey: "install:clickToken:\(scope):sent")

        let runway = LinkRunway(endpoint: Self.endpoint, publishableKey: key, suiteName: suite.name, session: session)
        await runway.setConsent(true)
        #expect(await runway.attributionToken() == "tok_legacy")
        #expect(try await runway.install() == nil)
        let id = try #require(await runway.installId())
        #expect(suite.contents["installId:\(scope)"] as? String == id)

        let match = try #require(try await runway.matchInstall())
        #expect(match.method == .referrer)
        #expect(match.path == "/welcome")
        #expect(match.metadata["campaign"] == .string("spring"))
        #expect(await runway.attributionToken() == "tok_loopback")
        #expect(LoopbackProtocol.log.sent(with: key, to: "/v1/installs/match").first?.request.httpMethod == "POST")

        // The next launch: a new instance reads the same identity and the stored answer from disk.
        let next = LinkRunway(endpoint: Self.endpoint, publishableKey: key, suiteName: suite.name, session: session)
        await next.setConsent(true)
        #expect(await next.installId() == id)
        #expect(try await next.matchInstall() == match)
        #expect(await next.attributionToken() == "tok_loopback")
        #expect(LoopbackProtocol.log.sent(with: key, to: "/v1/installs/match").count == 1)

        await next.setConsent(false)
        #expect(Set(suite.contents.keys) == ["install:clickToken:\(scope):sent", "matchResolved:\(scope)"])
        #expect(suite.contents.values.allSatisfy { $0 as? Bool == true })
    }

    /// The public surface added in 0.2, used the way the documentation shows it.
    @Test func theNewApiReadsAsDocumented() async throws {
        let suite = RealSuite()
        defer { suite.remove() }
        let runway = LinkRunway(endpoint: Self.endpoint, publishableKey: "lr_pk_new", suiteName: suite.name)

        let id: String? = await runway.installId()
        let match: InstallMatch? = try await runway.matchInstall()
        let rules: [ConversionRule] = try await runway.configureConversions(appId: "app_1")
        let update: ConversionUpdate? = await runway.recordConversion(event: "PURCHASE", amount: 4_999)
        let named: ConversionUpdate? = await runway.recordConversion(event: "CUSTOM", name: "level_10", amount: 0)
        let claim: AdServicesClaim? = try await runway.submitAdServicesToken()
        let status: AttestationStatus? = await runway.attest(appId: "app_1")
        let event: TrackingResult? = try await runway.track(type: "CUSTOM", name: "level_10")
        #expect(id == nil && match == nil && rules.isEmpty && update == nil && named == nil)
        #expect(claim == nil && status == nil && event == nil)

        if let match, match.matched, match.method == .probabilistic || match.method == .viewThrough, let path = match.path {
            _ = (path, match.url, match.clickId, match.metadata["campaign"])
        }
        if let update { _ = (update.fineValue, update.coarseValue == .high, update.lockWindow, update.frameworks.contains(.skAdNetwork)) }
        switch status {
        case .attested, .unsupported, .disabled, nil: break
        case .failed(let reason): _ = reason
        }
        switch claim {
        case .submitted, .alreadySubmitted, .pending, .unavailable, nil: break
        }
        #expect(!LinkRunway.sdkVersion.isEmpty)
        #expect(suite.contents.isEmpty)
    }

    /// The quick start in the ios README, as written there apart from consent, which stays off: nothing is sent.
    @Test func theDocumentedQuickStartCompilesAndRuns() async throws {
        let suite = RealSuite()
        defer { suite.remove() }
        let runway = LinkRunway(endpoint: Self.endpoint, publishableKey: "lr_pk_quick", suiteName: suite.name)
        let appID = "your_app_id"
        var routed: String?

        await runway.attest(appId: appID)
        _ = try? await runway.configureConversions(appId: appID)
        if let match = try? await runway.matchInstall(), match.matched, let path = match.path {
            routed = path
        }
        try await runway.install()
        _ = try? await runway.submitAdServicesToken()
        try await runway.track(type: "CUSTOM", name: "level_10")
        await runway.recordConversion(event: "PURCHASE", amount: 4999)

        #expect(routed == nil)
        #expect(suite.contents.isEmpty)
    }
}
