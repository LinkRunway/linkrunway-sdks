import Foundation
import Testing
@testable import LinkRunway

private let matched = Reply.json(
    #"{"matched":true,"method":"PROBABILISTIC","clickId":"clk_1","clickToken":"tok_match","path":"/p/1","url":"https://example.com/p/1","metadata":{}}"#)

private func everything(_ clock: TestClock) -> [String: [Reply]] {
    let expiry = Timestamp.string(clock.now.addingTimeInterval(86_400))
    return [
        "/v1/track": [.tracked],
        "/v1/installs/match": [matched],
        "/v1/claims/apple-ads": [.json("{}")],
        "/v1/mobile/config/app_1": [.json(#"{"id":"app_1","conversionRules":[{"event":"SIGNUP","minAmount":0,"fineValue":5,"coarseValue":"low","lockWindow":false}]}"#)],
        "/v1/attest/challenge": [.json(#"{"challengeId":"ch_1","challenge":"Y2hhbGxlbmdl"}"#)],
        "/v1/attest/apple/register": [.json(#"{"attestation":"attest-token","expiresAt":"\#(expiry)"}"#)],
        "/v1/shares": [.json(#"{"shareId":"shr_1","url":"https://go.example.com/l/a?s=shr_1"}"#)],
        "/v1/deferred": [.json(#"{"code":"ABCDEFGHJKLM","expiresAt":"\#(expiry)"}"#)],
    ]
}

@Suite struct ConsentTests {
    @Test func nothingIsSentOrStoredWithoutConsent() async throws {
        let clock = TestClock()
        let reads = Counter()
        let h = Harness(clock: clock, adServicesToken: { reads.increment(); return Harness.adToken }, everything(clock))
        let sdk = h.sdk

        // Consent is off until the app turns it on; turning it off again changes nothing.
        for explicit in [false, true] {
            if explicit { await sdk.setConsent(false) }
            #expect(try await sdk.open(URL(string: "https://go.example.com/l/spring")!) == nil)
            #expect(try await sdk.open(URL(string: "myapp://open?lr_token=tok_direct")!) == nil)
            #expect(try await sdk.track(type: "OPEN") == nil)
            #expect(try await sdk.track(type: "CUSTOM", name: "level_10") == nil)
            #expect(try await sdk.install() == nil)
            #expect(try await sdk.matchInstall() == nil)
            #expect(try await sdk.configureConversions(appId: "app_1").isEmpty)
            #expect(await sdk.recordConversion(event: "SIGNUP") == nil)
            #expect(try await sdk.submitAdServicesToken() == nil)
            #expect(await sdk.attest(appId: "app_1") == nil)
            #expect(try await sdk.claimReferralCode("ABCDEFGHJKLM", claimId: UUID()) == nil)
            await #expect(throws: LinkRunwayError.self) { try await sdk.createShare(linkId: "lnk_1") }
            await #expect(throws: LinkRunwayError.self) { try await sdk.createReferralCode() }
            #expect(await sdk.attributionToken() == nil)
            #expect(await sdk.installId() == nil)
        }

        #expect(await h.transport.requests.isEmpty)
        #expect(h.stored.isEmpty)
        #expect(reads.value == 0)
        #expect(await h.appAttest.generated.isEmpty)
        #expect(await h.conversions.updates.isEmpty)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func withdrawalClearsTheInstallIdTheTokenAndTheAttestation() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, everything(clock))
        let sdk = h.sdk
        await sdk.setConsent(true)
        let installId = try #require(await sdk.installId())

        #expect(try await sdk.matchInstall()?.matched == true)
        #expect(await sdk.attest(appId: "app_1") == .attested)
        #expect(try await sdk.configureConversions(appId: "app_1").count == 1)
        #expect(try await sdk.track(type: "SIGNUP") != nil)
        #expect(try await sdk.install() != nil)
        await sdk.settle()
        #expect(try await sdk.submitAdServicesToken() == .submitted)
        #expect(await sdk.attributionToken() == "tok_match")
        // While consent is on, this is everything the SDK keeps. The only other entry is the wait after a failed attestation.
        let kept = Set(Store.Key.allCases).subtracting([.attestBackoff])
        #expect(h.storedKeys == kept)
        #expect(h.stored.count == kept.count)
        #expect(h.store.string(.installId) == installId)

        await sdk.setConsent(false)

        #expect(await sdk.installId() == nil)
        #expect(await sdk.attributionToken() == nil)
        // Three booleans remain so this installation is never reported twice. No identifier or token survives.
        #expect(h.storedKeys == [.installSent, .matchResolved, .adServicesDone])
        #expect(h.stored.count == 3)
        #expect(h.stored.values.allSatisfy { $0 as? Bool == true })
        let text = String(describing: h.stored)
        for secret in [installId, "tok_match", "attest-token", "key-1"] { #expect(!text.contains(secret)) }

        // With consent off again, nothing more is sent.
        let before = await h.transport.requests.count
        #expect(try await sdk.track(type: "OPEN") == nil)
        #expect(await sdk.recordConversion(event: "SIGNUP") == nil)
        #expect(await h.transport.requests.count == before)
    }

    @Test func consentGivenAgainStartsANewIdentityWithoutRecountingTheInstall() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, everything(clock))
        let sdk = h.sdk
        await sdk.setConsent(true)
        let first = try #require(await sdk.installId())
        try await sdk.matchInstall()
        try await sdk.install()
        try await sdk.submitAdServicesToken()
        await sdk.setConsent(false)
        await sdk.setConsent(true)

        let second = try #require(await sdk.installId())
        #expect(second != first)
        #expect(await sdk.attributionToken() == nil)
        let before = await h.transport.requests.count
        // The first launch was already matched, the INSTALL reported, and the Apple Ads claim made.
        #expect(try await sdk.matchInstall() == InstallMatch.unmatched)
        #expect(try await sdk.install() == nil)
        #expect(try await sdk.submitAdServicesToken() == .alreadySubmitted)
        #expect(await h.transport.requests.count == before)

        try await sdk.track(type: "OPEN")
        let event = try #require(await h.transport.requests.last)
        #expect(event.text("installId") == second)
        #expect(event.text("clickToken") == nil)
        #expect(event.text("attestation") == nil)
    }

    @Test func aResponseThatArrivesAfterWithdrawalIsDiscarded() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, everything(clock))
        let sdk = h.sdk
        await sdk.setConsent(true)
        let first = try #require(await sdk.installId())
        // Consent is withdrawn and given again while the match request is in flight.
        await h.transport.whileInFlight { request in
            guard request.path == "/v1/installs/match" else { return }
            await sdk.setConsent(false)
            await sdk.setConsent(true)
        }

        #expect(try await sdk.matchInstall() == nil)
        #expect(await sdk.attributionToken() == nil)
        let second = try #require(await sdk.installId())
        #expect(second != first)
        // Only the new identity is stored: the answer belonged to the withdrawn one.
        #expect(h.storedKeys == [.installId])
        #expect(h.store.string(.installId) == second)
    }

    @Test func withdrawalDuringRetriesStopsTheRequest() async throws {
        let h = Harness(["/v1/track": [.status(503)]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        await h.transport.whileInFlight { _ in await sdk.setConsent(false) }

        await #expect(throws: LinkRunwayError.self) { try await sdk.track(type: "OPEN") }
        #expect(await h.transport.requests.count == 1)
        #expect(h.stored.isEmpty)
    }

    @Test func anUpgradeKeepsTheTokenAndInstallMarkerFromTheFirstSdk() async throws {
        let h = Harness(["/v1/track": [.tracked]])
        // The key names SDK 0.1 wrote.
        let scope = "\(Harness.endpoint.absoluteString):\(Harness.key.prefix(20))"
        h.memory.set("tok_legacy", forKey: "clickToken:\(scope)")
        h.memory.set("legacy-install-event", forKey: "install:clickToken:\(scope)")
        h.memory.set(true, forKey: "install:clickToken:\(scope):sent")

        await h.sdk.setConsent(true)
        #expect(await h.sdk.attributionToken() == "tok_legacy")
        #expect(try await h.sdk.install() == nil)
        try await h.sdk.track(type: "OPEN")
        let event = try #require(await h.transport.requests.first)
        #expect(event.text("clickToken") == "tok_legacy")
        #expect(event.text("installId") != nil)
    }
}
