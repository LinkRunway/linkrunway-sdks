import CryptoKit
import Foundation
import Testing
@testable import LinkRunway

/// The API validates bodies with strict schemas, so a request may carry only the fields its contract lists.
@Suite struct RequestEncodingTests {
    /// `z.uuid()` in the contracts, in the lower-case form the SDK stores.
    static let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
    /// The pattern the API uses to recognise SDK traffic (`tracking/context.ts`).
    static let agent = #"^LinkRunwaySDK/[0-9.]+ (iOS|Android|tvOS|AndroidTV|ReactNative|Flutter)$"#

    private func expectCommonHeaders(_ request: Recorded, json: Bool = true) {
        #expect(request.headers["Authorization"] == "Bearer \(Harness.key)")
        #expect(request.headers["User-Agent"]?.range(of: Self.agent, options: .regularExpression) != nil)
        #expect(request.headers["Content-Type"] == (json ? "application/json" : nil))
    }

    @Test func trackCarriesTheInstallIdAndOnlyContractFields() async throws {
        let h = Harness(["/v1/track": [.tracked]])
        await h.sdk.setConsent(true)
        let installId = try #require(await h.sdk.installId())
        #expect(installId.range(of: Self.uuid, options: .regularExpression) != nil)

        let result = try await h.sdk.track(type: "CUSTOM", name: "level_10", eventId: "evt-1", userId: "user-1",
                                           metadata: ["plan": "pro"], occurredAt: Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(result?.id == "evt_1")
        #expect(result?.attributed == true)

        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://go.example.com/v1/track")
        expectCommonHeaders(request)
        #expect(request.keys == ["eventId", "type", "name", "externalUserId", "metadata", "consent", "occurredAt", "installId"])
        #expect(request.text("eventId") == "evt-1")
        #expect(request.text("type") == "CUSTOM")
        #expect(request.text("name") == "level_10")
        #expect(request.text("externalUserId") == "user-1")
        #expect(request.json["metadata"] as? [String: String] == ["plan": "pro"])
        #expect(request.json["consent"] as? Bool == true)
        #expect(request.text("occurredAt") == "2023-11-14T22:13:20.500Z")
        #expect(request.text("installId") == installId)
    }

    @Test func everyEventCarriesTheSameInstallId() async throws {
        let h = Harness(["/v1/track": [.tracked]])
        await h.sdk.setConsent(true)
        try await h.sdk.track(type: "OPEN")
        try await h.sdk.track(type: "SIGNUP", userId: "user-1")
        try await h.sdk.install()
        let next = h.relaunched(["/v1/track": [.tracked]])
        await next.sdk.setConsent(true)
        try await next.sdk.track(type: "OPEN")

        let sent = await h.transport.requests + next.transport.requests
        #expect(sent.map { $0.text("type") } == ["OPEN", "SIGNUP", "INSTALL", "OPEN"])
        #expect(Set(sent.map { $0.text("installId") }).count == 1)
        #expect(sent[0].text("installId") == (await next.sdk.installId()))
        // The plain form sends no optional field it has no value for.
        #expect(sent[0].keys == ["eventId", "type", "metadata", "consent", "occurredAt", "installId"])
    }

    @Test func revenueEventsAreRefusedBeforeAnyRequest() async throws {
        let h = Harness(["/v1/track": [.tracked]])
        await h.sdk.setConsent(true)
        for type in ["PURCHASE", "SUBSCRIPTION", "REFUND", "open"] {
            await #expect(throws: LinkRunwayError.self) { try await h.sdk.track(type: type) }
        }
        #expect(await h.transport.requests.isEmpty)
    }

    @Test func matchRequestDescribesTheInstallation() async throws {
        let h = Harness(["/v1/installs/match": [.json(#"{"matched":false,"method":"NONE"}"#)]])
        await h.sdk.setConsent(true)
        try await h.sdk.matchInstall()

        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://go.example.com/v1/installs/match")
        expectCommonHeaders(request)
        #expect(request.keys == ["installId", "platform", "osVersion", "language", "consent"])
        #expect(request.text("installId") == (await h.sdk.installId()))
        #expect(request.text("platform") == Platform.name)
        #expect(request.text("osVersion") == "18.2")
        #expect(request.text("language") == "en-US")
        #expect(request.json["consent"] as? Bool == true)
    }

    @Test func claimRequestCarriesTheAppleToken() async throws {
        let h = Harness(["/v1/claims/apple-ads": [.json(#"{"claimed":true}"#, status: 201)]])
        await h.sdk.setConsent(true)
        #expect(try await h.sdk.submitAdServicesToken() == .submitted)

        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://go.example.com/v1/claims/apple-ads")
        expectCommonHeaders(request)
        #expect(request.keys == ["installId", "token", "consent"])
        #expect(request.text("installId") == (await h.sdk.installId()))
        #expect(request.text("token") == Harness.adToken)
        #expect(request.json["consent"] as? Bool == true)
    }

    @Test func attestationRequestsFollowTheChallenge() async throws {
        // A base64url challenge whose decoded bytes differ from its text: the hash must cover the text.
        let challenge = "Y2hhbGxlbmdlLW9uZQ-_"
        let clock = TestClock()
        let issued = #"{"attestation":"attest-token-1","expiresAt":"\#(Timestamp.string(clock.now.addingTimeInterval(86_400)))"}"#
        let h = Harness(clock: clock, [
            "/v1/attest/challenge": [.json(#"{"challengeId":"ch_1","challenge":"\#(challenge)"}"#)],
            "/v1/attest/apple/register": [.json(issued)],
            "/v1/attest/apple/assert": [.json(issued)],
            "/v1/track": [.tracked],
        ])
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)

        let sent = await h.transport.requests
        #expect(sent.map(\.path) == ["/v1/attest/challenge", "/v1/attest/apple/register"])
        expectCommonHeaders(sent[0])
        #expect(sent[0].keys == ["appId"])
        #expect(sent[0].text("appId") == "app_1")
        expectCommonHeaders(sent[1])
        #expect(sent[1].keys == ["appId", "challengeId", "keyId", "attestation"])
        #expect(sent[1].text("appId") == "app_1")
        #expect(sent[1].text("challengeId") == "ch_1")
        #expect(sent[1].text("keyId") == "key-1")
        // Standard base64 of the attestation object, exactly as App Attest returned it.
        #expect(sent[1].text("attestation") == Data("attestation-object:key-1".utf8).base64EncodedString())
        let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
        let attested = await h.appAttest.attestations
        #expect(attested.map(\.keyId) == ["key-1"])
        #expect(attested.map(\.hash) == [hash])

        // The token is then attached to events.
        try await h.sdk.track(type: "OPEN")
        let event = try #require(await h.transport.sent("/v1/track").first)
        #expect(event.text("attestation") == "attest-token-1")
        #expect(event.keys == ["eventId", "type", "metadata", "consent", "occurredAt", "installId", "attestation"])

        // After it expires the registered key signs a new challenge instead of being attested again.
        clock.advance(86_400)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        let renewal = try #require(await h.transport.sent("/v1/attest/apple/assert").first)
        expectCommonHeaders(renewal)
        #expect(renewal.keys == ["appId", "challengeId", "keyId", "assertion"])
        #expect(renewal.text("keyId") == "key-1")
        #expect(renewal.text("challengeId") == "ch_1")
        #expect(renewal.text("assertion") == Data("assertion:key-1".utf8).base64EncodedString())
        let asserted = await h.appAttest.assertions
        #expect(asserted.map(\.hash) == [hash])
        #expect(await h.appAttest.generated == ["key-1"])
    }

    @Test func conversionRulesAreFetchedWithAGet() async throws {
        let h = Harness(["/v1/mobile/config/app_1": [.json(#"{"id":"app_1","conversionRules":[]}"#)]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url == "https://go.example.com/v1/mobile/config/app_1")
        #expect(request.body == nil)
        expectCommonHeaders(request, json: false)
    }

    @Test func anAppIdIsAlwaysOnePathSegment() async throws {
        let h = Harness()
        await h.sdk.setConsent(true)
        _ = try? await h.sdk.configureConversions(appId: "../track?x=1/y z")
        let request = try #require(await h.transport.requests.first)
        #expect(request.url == "https://go.example.com/v1/mobile/config/%2E%2E%2Ftrack%3Fx%3D1%2Fy%20z")
    }

    @Test func resolveKeepsItsContract() async throws {
        let link = #"{"clickId":"clk_1","clickToken":"tok_1","metadata":{"campaign":"spring"},"path":"/p/1","url":"https://example.com/p/1"}"#
        let h = Harness(["/v1/resolve": [.json(link)]])
        await h.sdk.setConsent(true)
        let resolved = try await h.sdk.open(URL(string: "https://go.example.com/l/spring")!)
        #expect(resolved?.path == "/p/1")
        #expect(resolved?.metadata == ["campaign": .string("spring")])
        let request = try #require(await h.transport.requests.first)
        #expect(request.keys == ["url", "consent", "platform"])
        // `/v1/resolve` accepts ios, android, and web only, on every Apple platform.
        #expect(request.text("platform") == "ios")
        #expect(await h.sdk.attributionToken() == "tok_1")
    }

    @Test func platformStringsMatchWhatTheApiAccepts() {
        #if os(tvOS)
        #expect(Platform.name == "tvos")
        #expect(Platform.userAgent == "LinkRunwaySDK/\(LinkRunway.sdkVersion) tvOS")
        #else
        #expect(Platform.name == "ios")
        #expect(Platform.userAgent == "LinkRunwaySDK/\(LinkRunway.sdkVersion) iOS")
        #endif
        #expect(Platform.userAgent.range(of: Self.agent, options: .regularExpression) != nil)
        #expect(Platform.language("en-US") == "en-US")
        #expect(Platform.language("zh-Hans-CN") == "zh-Hans-CN")
        #expect(Platform.language("es-419") == "es-419")
        #expect(Platform.language("en_US") == nil)
        #expect(Platform.language("e") == nil)
        #expect(Platform.language(String(repeating: "en-", count: 12) + "US") == nil)
        #expect(Platform.language(nil) == nil)
        #expect(Timestamp.date("2026-10-11T09:00:00.000Z") == Timestamp.date("2026-10-11T09:00:00Z"))
        #expect(Timestamp.date("tomorrow") == nil)
    }
}
