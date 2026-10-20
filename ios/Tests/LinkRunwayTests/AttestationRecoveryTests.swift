import Foundation
import Testing
@testable import LinkRunway

private let challenge = Attest.challenge, register = Attest.register, assert = Attest.assert, track = Attest.track
private func issued(_ token: String, _ clock: TestClock, validFor seconds: TimeInterval = 86_400) -> Reply {
    Attest.issued(token, clock, validFor: seconds)
}

/// What happens to the App Attest key when the device, Apple, or the server stops accepting it.
@Suite struct AttestationRecoveryTests {
    @Test func aKeyTheDeviceLostIsReplacedInTheSameCall() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock, register: [issued("token-1", clock), issued("token-3", clock, validFor: 2 * 86_400)]))
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)

        // After a restore from backup the key ID is still stored but the Secure Enclave key is gone.
        clock.advance(86_400)
        await h.appAttest.failNextAssertions([.invalidKey])
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        #expect(await h.transport.paths == [challenge, register, challenge, challenge, register])
        #expect(await h.appAttest.generated == ["key-1", "key-2"])
        #expect(await h.transport.sent(register).map { $0.text("keyId") } == ["key-1", "key-2"])
        try await h.sdk.track(type: "OPEN")
        #expect(await h.transport.sent(track).first?.text("attestation") == "token-3")
    }

    /// 404 is the one server answer that replaces a registered key. Any other rejection keeps it, and the next attempt,
    /// after the wait, asserts with the same key for a fresh challenge. Apple limits how many keys a device may create.
    @Test(arguments: [(404, true), (400, false), (401, false), (403, false), (409, false), (422, false), (429, false)])
    func onlyA404ToAnAssertionReplacesTheKey(status: Int, replaces: Bool) async throws {
        let clock = TestClock()
        let challenges = (1...4).map { Reply.json(#"{"challengeId":"ch_\#($0)","challenge":"challenge-\#($0)"}"#) }
        // A 429 gets the usual three attempts; other client errors are not retried.
        let rejected = [Reply](repeating: .status(status), count: status == 429 ? 3 : 1)
        let h = Harness(clock: clock, Attest.table(clock, register: [issued("token-1", clock), issued("token-3", clock, validFor: 2 * 86_400)],
                                                   assert: rejected + [issued("token-2", clock, validFor: 2 * 86_400)],
                                                   challenge: challenges))
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        clock.advance(86_400)
        let renewal = await h.sdk.attest(appId: "app_1")
        if replaces {
            // The server does not know the key: a new one is registered in the same call.
            #expect(renewal == .attested)
            #expect(await h.appAttest.generated == ["key-1", "key-2"])
            #expect(await h.transport.sent(register).map { $0.text("keyId") } == ["key-1", "key-2"])
            return
        }
        guard case .failed = renewal else {
            Issue.record("A rejected assertion should fail the attempt")
            return
        }
        clock.advance(300)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        #expect(await h.appAttest.generated == ["key-1"])
        #expect(await h.transport.sent(register).count == 1)
        let assertions = await h.transport.sent(assert)
        #expect(Set(assertions.map { $0.text("keyId") }) == ["key-1"])
        #expect(Set(assertions.map { $0.text("challengeId") }) == ["ch_2", "ch_3"])
    }

    @Test func anAppleOutageIsRetriedWithTheSameKeyAndHash() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        await h.sdk.setConsent(true)
        await h.appAttest.failNextAttestations([.serverUnavailable, .serverUnavailable])

        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        let attempts = await h.appAttest.attestations
        #expect(attempts.count == 3)
        #expect(Set(attempts.map(\.keyId)) == ["key-1"])
        #expect(Set(attempts.map(\.hash)).count == 1)
        #expect(clock.sleeps == [1, 2])
        #expect(await h.transport.paths == [challenge, register])
    }

    @Test func aLongAppleOutageKeepsTheUnattestedKey() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock))
        await h.sdk.setConsent(true)
        await h.appAttest.failNextAttestations([.serverUnavailable, .serverUnavailable, .serverUnavailable])
        guard case .failed = await h.sdk.attest(appId: "app_1") else {
            Issue.record("Three failures should end the attempt")
            return
        }
        clock.advance(300)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        // The key was never attested, so the same one is used.
        #expect(await h.appAttest.generated == ["key-1"])
        #expect(await h.transport.sent(register).first?.text("keyId") == "key-1")
    }

    @Test func aRefusedRegistrationKeepsTheKeyUntilAnAssertionIsAnswered404() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock, register: [.status(400), issued("token-1", clock)], assert: [.status(404)]))
        await h.sdk.setConsent(true)
        guard case .failed = await h.sdk.attest(appId: "app_1") else {
            Issue.record("A refused registration should fail the attempt")
            return
        }
        // Apple attests a key only once, so it is kept and the next attempt asserts with it.
        #expect(h.storedKeys.contains(.attestation))
        clock.advance(300)
        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        // The server answered that assertion 404, so a new key was registered in the same call.
        #expect(await h.transport.paths == [challenge, register, challenge, assert, challenge, register])
        #expect(await h.transport.sent(register).map { $0.text("keyId") } == ["key-1", "key-2"])
    }

    @Test func aRegistrationWithNoResponseIsTriedAsAnAssertionFirst() async throws {
        let clock = TestClock()
        // The registration reached nobody as far as the app can tell, yet the server may have stored it.
        let stored = Harness(clock: clock, Attest.table(clock, register: [.offline]))
        await stored.sdk.setConsent(true)
        guard case .failed = await stored.sdk.attest(appId: "app_1") else {
            Issue.record("A registration without a response should fail the attempt")
            return
        }
        clock.advance(300)
        #expect(await stored.sdk.attest(appId: "app_1") == .attested)
        #expect(await stored.transport.sent(assert).first?.text("keyId") == "key-1")
        #expect(await stored.appAttest.generated == ["key-1"])

        // When the server did not store it, its 404 leads to a new key.
        let lost = Harness(clock: clock, Attest.table(clock, register: [.offline, .offline, .offline, issued("token-1", clock)],
                                                       assert: [.status(404)]))
        await lost.sdk.setConsent(true)
        _ = await lost.sdk.attest(appId: "app_1")
        clock.advance(300)
        #expect(await lost.sdk.attest(appId: "app_1") == .attested)
        #expect(await lost.transport.sent(register).last?.text("keyId") == "key-2")
    }

    @Test func repeatedFailuresWaitLongerEachTime() async throws {
        let clock = TestClock()
        let h = Harness(clock: clock, Attest.table(clock, challenge: [.status(503)]))
        await h.sdk.setConsent(true)
        func attempt() async -> Int {
            _ = await h.sdk.attest(appId: "app_1")
            return await h.transport.sent(challenge).count
        }
        // Each real attempt makes three requests (the usual retries) and fails.
        #expect(await attempt() == 3)
        clock.advance(300)
        #expect(await attempt() == 6)
        // After the second failure the wait is ten minutes, not five.
        clock.advance(300)
        #expect(await attempt() == 6)
        clock.advance(300)
        #expect(await attempt() == 9)
        // And twenty after the third.
        clock.advance(900)
        #expect(await attempt() == 9)
        clock.advance(300)
        #expect(await attempt() == 12)
        #expect(await h.appAttest.generated.isEmpty)
    }

    @Test func aDeviceClockAheadOfTheServerDoesNotRenewOnEveryEvent() async throws {
        let clock = TestClock()
        // To this device every token the server issues looks a day past its expiry.
        let expired = Attest.issued("token-skewed", clock, validFor: -86_400)
        let h = Harness(clock: clock, Attest.table(clock, register: [expired], assert: [expired]))
        await h.sdk.setConsent(true)

        #expect(await h.sdk.attest(appId: "app_1") == .attested)
        for _ in 0..<3 { try await h.sdk.track(type: "OPEN") }
        // The new token is attached and used for five minutes before the SDK asks again.
        #expect(await h.transport.sent(track).map { $0.text("attestation") } == ["token-skewed", "token-skewed", "token-skewed"])
        #expect(await h.transport.sent(challenge).count == 1)

        clock.advance(300)
        try await h.sdk.track(type: "OPEN")
        #expect(await h.transport.sent(assert).count == 1)
        #expect(await h.transport.sent(challenge).count == 2)
        #expect(await h.appAttest.generated == ["key-1"])
    }

    @Test func theWaitAfterAFailureOutlivesTheProcess() async throws {
        let clock = TestClock()
        let refusing = Attest.table(clock, register: [.status(400)], assert: [.status(404)])
        let h = Harness(clock: clock, refusing)
        await h.sdk.setConsent(true)
        guard case .failed = await h.sdk.attest(appId: "app_1") else {
            Issue.record("A refused registration should fail the attempt")
            return
        }
        #expect(await h.appAttest.generated == ["key-1"])

        // The next launch, a minute later, creates no key and sends nothing.
        clock.advance(60)
        let next = h.relaunched(refusing)
        await next.sdk.setConsent(true)
        guard case .failed = await next.sdk.attest(appId: "app_1") else {
            Issue.record("The wait should still apply")
            return
        }
        #expect(await next.transport.requests.isEmpty)
        #expect(await next.appAttest.generated.isEmpty)

        // After the wait it tries again (the kept key is answered 404, so one new key), and the second failure
        // doubles the wait.
        clock.advance(240)
        _ = await next.sdk.attest(appId: "app_1")
        #expect(await next.appAttest.generated == ["key-1"])
        let afterRetry = await next.transport.sent(challenge).count
        clock.advance(300)
        _ = await next.sdk.attest(appId: "app_1")
        #expect(await next.transport.sent(challenge).count == afterRetry)

        // A clock set back by a day does not leave the SDK waiting a day.
        clock.advance(-86_400)
        _ = await next.sdk.attest(appId: "app_1")
        #expect(await next.transport.sent(challenge).count > afterRetry)

        // Withdrawing consent removes the wait with everything else.
        await next.sdk.setConsent(false)
        #expect(!next.storedKeys.contains(.attestBackoff))
    }
}
