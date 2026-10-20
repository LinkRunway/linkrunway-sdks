import Foundation
import Testing
@testable import LinkRunway

/// Paths and canned replies for the attestation endpoints.
enum Attest {
    static let challenge = "/v1/attest/challenge"
    static let register = "/v1/attest/apple/register"
    static let assert = "/v1/attest/apple/assert"
    static let track = "/v1/track"

    static func issued(_ token: String, _ clock: TestClock, validFor seconds: TimeInterval = 86_400) -> Reply {
        .json(#"{"attestation":"\#(token)","expiresAt":"\#(Timestamp.string(clock.now.addingTimeInterval(seconds)))"}"#)
    }

    static func table(_ clock: TestClock, register registration: [Reply]? = nil, assert assertion: [Reply]? = nil,
                      challenge challenges: [Reply]? = nil) -> [String: [Reply]] {
        [
            challenge: challenges ?? [.json(#"{"challengeId":"ch_1","challenge":"Y2hhbGxlbmdlLW9uZQ"}"#),
                                      .json(#"{"challengeId":"ch_2","challenge":"Y2hhbGxlbmdlLXR3bw"}"#)],
            register: registration ?? [issued("token-1", clock)],
            assert: assertion ?? [issued("token-2", clock, validFor: 2 * 86_400)],
            track: [.tracked],
        ]
    }
}

private let challenge = Attest.challenge, register = Attest.register, assert = Attest.assert, track = Attest.track

@Suite struct AttestationTests {
    @Test func theTokenIsCachedUntilItExpiresThenRenewedByAssertion() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        await h.sdk.setConsent(true)

        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        try await h.sdk.track(type: "OPEN")
        clock.advance(86_400 - 61)
        try await h.sdk.track(type: "OPEN")
        // One registration served both calls and both events.
        #expect(await h.transport.paths == [challenge, register, track, track])
        #expect(await h.transport.sent(track).map { $0.text("attestation") } == ["token-1", "token-1"])

        // Inside the last minute the token counts as expired, and the next event renews it first.
        clock.advance(2)
        try await h.sdk.track(type: "OPEN")
        #expect(await h.transport.paths == [challenge, register, track, track, challenge, assert, track])
        #expect(await h.transport.sent(track).last?.text("attestation") == "token-2")
        #expect(await h.transport.sent(assert).first?.text("challengeId") == "ch_2")
        #expect(await h.appAttest.generated == ["key-1"])
        #expect(await h.appAttest.attestations.count == 1)
        #expect(await h.appAttest.assertions.map(\.keyId) == ["key-1"])
    }

    @Test func aRelaunchReusesTheKeyAndTheToken() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)

        let next = h.relaunched(Attest.table(clock))
        await next.sdk.setConsent(true)
        // The stored token is attached even before the app asks again.
        try await next.sdk.track(type: "OPEN")
        #expect(await next.transport.sent(track).first?.text("attestation") == "token-1")
        #expect(await next.sdk.attest(appId: "app_1") == .attested)
        #expect(await next.transport.paths == [track])

        clock.advance(86_400)
        #expect(await next.sdk.attest(appId: "app_1") == .attested)
        #expect(await next.transport.paths == [track, challenge, assert])
        #expect(await next.transport.sent(assert).first?.text("keyId") == "key-1")
        #expect(await next.appAttest.generated.isEmpty)
    }

    @Test func unsupportedEnvironmentsAreANoOp() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, appAttest: FakeAppAttest(isSupported: false), Attest.table(clock))
        await h.sdk.setConsent(true)

        #expect(await h.sdk.attest(appId: "app_1") == .unsupported)
        try await h.sdk.track(type: "OPEN")
        #expect(await h.transport.paths == [track])
        #expect(await h.transport.sent(track).first?.text("attestation") == nil)
        #expect(!h.storedKeys.contains(.attestation))
    }

    @Test func failuresNeverBlockTrackingAndAreNotRetriedOnEveryEvent() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock, challenge: [.status(503), .status(503), .status(503),
                                                              .json(#"{"challengeId":"ch_9","challenge":"bGF0ZXI"}"#)]))
        await h.sdk.setConsent(true)

        guard case .failed(let reason) = await h.sdk.attest(appId: "app_1") else {
            Issue.record("An unreachable server should fail the attempt")
            return
        }
        #expect(reason.contains("503"))
        #expect(await h.appAttest.generated.isEmpty)

        // Events go out unattested, and the five-minute wait keeps them from repeating the attempt.
        #expect(try await h.sdk.track(type: "OPEN") != nil)
        #expect(try await h.sdk.track(type: "SIGNUP") != nil)
        #expect(await h.transport.sent(track).allSatisfy { $0.text("attestation") == nil })
        #expect(await h.transport.sent(challenge).count == 3)
        guard case .failed = await h.sdk.attest(appId: "app_1") else {
            Issue.record("The wait applies to explicit calls too")
            return
        }
        #expect(await h.transport.sent(challenge).count == 3)

        clock.advance(300)
        try await h.sdk.track(type: "OPEN")
        #expect(await h.transport.sent(challenge).count == 4)
        #expect(await h.transport.sent(track).last?.text("attestation") == "token-1")
        // A success clears the stored wait, so a later failure starts again at five minutes.
        #expect(!h.storedKeys.contains(.attestBackoff))
    }

    @Test func aDeclinedChallengeCreatesNoKey() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock, challenge: [.status(404)]))
        await h.sdk.setConsent(true)
        guard case .failed = await h.sdk.attest(appId: "missing") else {
            Issue.record("A declined challenge should fail the attempt")
            return
        }
        #expect(await h.appAttest.generated.isEmpty)
        #expect(await h.transport.paths == [challenge])
        #expect(!h.storedKeys.contains(.attestation))
    }

    @Test func concurrentCallsRegisterOneKey() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        let sdk = h.sdk
        await sdk.setConsent(true)
        let gate = Gate()
        await h.transport.whileInFlight { _ in await gate.pass() }

        async let first = sdk.attest(appId: "app_1")
        #expect(await eventually { await !h.transport.requests.isEmpty })
        async let second = sdk.attest(appId: "app_1")
        async let event = sdk.track(type: "OPEN")
        await breathe()
        await gate.open()

        #expect(await first == .attested)
        #expect(await second == .attested)
        #expect(try await event != nil)
        #expect(await h.appAttest.generated == ["key-1"])
        #expect(await h.transport.sent(register).count == 1)
        // The event waited for the attestation in progress instead of going out without it.
        #expect(await h.transport.sent(track).first?.text("attestation") == "token-1")
    }

    @Test func attestationTurnedOffStopsForThisLaunchAndKeepsTheKey() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)

        // A day later the token has expired and the owner has turned attestation off: the challenge is answered 409.
        clock.advance(86_400)
        let off = h.relaunched(Attest.table(clock, challenge: [.status(409)]))
        await off.sdk.setConsent(true)
        #expect(await off.sdk.attest(appId: "app_1") == .disabled)
        // No failure, no stored wait, no retries: events go out unattested and nothing more is requested.
        for _ in 0..<2 { try await off.sdk.track(type: "OPEN") }
        clock.advance(3_600)
        #expect(await off.sdk.attest(appId: "app_1") == .disabled)
        #expect(await off.transport.paths == [challenge, track, track])
        #expect(await off.transport.sent(track).allSatisfy { $0.text("attestation") == nil })
        #expect(!off.storedKeys.contains(.attestBackoff))
        #expect(await off.appAttest.generated.isEmpty)

        // The next launch asks again. With attestation back on, the kept key asserts.
        let on = off.relaunched(Attest.table(clock))
        await on.sdk.setConsent(true)
        #expect(await on.sdk.attest(appId: "app_1") == .attested)
        #expect(await on.transport.paths == [challenge, assert])
        #expect(await on.transport.sent(assert).first?.text("keyId") == "key-1")
        #expect(await on.appAttest.generated.isEmpty)
    }
}
