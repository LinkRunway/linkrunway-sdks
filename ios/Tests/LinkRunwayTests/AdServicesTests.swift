import Foundation
import Testing
@testable import LinkRunway

private let path = "/v1/claims/apple-ads"
private let pending = Reply.json(#"{"pending":true}"#, status: 202)
private let claimed = Reply.json(#"{"claimed":true}"#, status: 201)

private struct NoToken: Error {}

@Suite struct AdServicesTests {
    @Test func theTokenIsSubmittedOncePerInstallation() async throws {
        let reads = Counter()
        let h = Harness(adServicesToken: { reads.increment(); return Harness.adToken }, [path: [.json("{}")]])
        await h.sdk.setConsent(true)

        #expect(try await h.sdk.submitAdServicesToken() == .submitted)
        #expect(try await h.sdk.submitAdServicesToken() == .alreadySubmitted)
        #expect(await h.transport.sent(path).count == 1)
        #expect(reads.value == 1)
        #expect(h.clock.sleeps.isEmpty)

        let next = h.relaunched([path: [.json("{}")]])
        await next.sdk.setConsent(true)
        #expect(try await next.sdk.submitAdServicesToken() == .alreadySubmitted)
        #expect(await next.transport.requests.isEmpty)
    }

    @Test func aPendingAnswerIsRetriedFiveSecondsApart() async throws {
        let h = Harness([path: [pending, pending, claimed]])
        await h.sdk.setConsent(true)

        #expect(try await h.sdk.submitAdServicesToken() == .submitted)
        let sent = await h.transport.sent(path)
        #expect(sent.count == 3)
        // The same token and install ID each time: Apple is still processing that token.
        #expect(Set(sent.map { $0.text("token") }) == [Harness.adToken])
        #expect(Set(sent.map { $0.text("installId") }).count == 1)
        #expect(h.clock.sleeps == [5, 5])
        #expect(h.storedKeys.contains(.adServicesDone))
    }

    @Test func theServerMayNameTheRetryInterval() async throws {
        let h = Harness([path: [.json(#"{"pending":true,"retryAfterSeconds":2}"#, status: 202),
                                .json(#"{"pending":true,"retryAfterSeconds":900}"#, status: 202), claimed]])
        await h.sdk.setConsent(true)
        #expect(try await h.sdk.submitAdServicesToken() == .submitted)
        // Followed within reason: never longer than thirty seconds.
        #expect(h.clock.sleeps == [2, 30])
    }

    @Test func itStopsAfterThreeRetriesAndCanBeCalledAgainLater() async throws {
        let h = Harness([path: [pending, pending, pending, pending, claimed]])
        await h.sdk.setConsent(true)

        #expect(try await h.sdk.submitAdServicesToken() == .pending)
        // One request and three retries, with no wait after the last answer.
        #expect(await h.transport.sent(path).count == 4)
        #expect(h.clock.sleeps == [5, 5, 5])
        #expect(!h.storedKeys.contains(.adServicesDone))

        #expect(try await h.sdk.submitAdServicesToken() == .submitted)
        #expect(await h.transport.sent(path).count == 5)
        #expect(try await h.sdk.submitAdServicesToken() == .alreadySubmitted)
    }

    @Test func aMissingTokenIsNotAnError() async throws {
        let none = Harness(adServicesToken: nil, [path: [claimed]])
        await none.sdk.setConsent(true)
        #expect(try await none.sdk.submitAdServicesToken() == .unavailable)

        // What AdServices does in the Simulator.
        let failing = Harness(adServicesToken: { throw NoToken() }, [path: [claimed]])
        await failing.sdk.setConsent(true)
        #expect(try await failing.sdk.submitAdServicesToken() == .unavailable)

        for harness in [none, failing] {
            #expect(await harness.transport.requests.isEmpty)
            #expect(!harness.storedKeys.contains(.adServicesDone))
        }
    }

    @Test func aRejectedClaimIsThrownAndNotMarkedDone() async throws {
        let h = Harness([path: [.status(400), claimed]])
        await h.sdk.setConsent(true)

        do {
            try await h.sdk.submitAdServicesToken()
            Issue.record("A 400 should be thrown")
        } catch LinkRunwayError.server(let status, _) {
            #expect(status == 400)
        }
        #expect(await h.transport.sent(path).count == 1)
        #expect(!h.storedKeys.contains(.adServicesDone))
        #expect(try await h.sdk.submitAdServicesToken() == .submitted)
    }

    @Test func concurrentCallsMakeOneClaim() async throws {
        let h = Harness([path: [claimed]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        let gate = Gate()
        await h.transport.whileInFlight { _ in await gate.pass() }

        async let first = sdk.submitAdServicesToken()
        #expect(await eventually { await !h.transport.requests.isEmpty })
        async let second = sdk.submitAdServicesToken()
        await breathe()
        await gate.open()

        let results = try await [first, second]
        // The second call either joined the first or found it finished; either way one request was made.
        #expect(results[0] == .submitted)
        #expect(results[1] == .submitted || results[1] == .alreadySubmitted)
        #expect(await h.transport.sent(path).count == 1)
    }

    @Test func theLiveReaderExistsOnlyWhereAdServicesDoes() {
        #if os(iOS) && canImport(AdServices)
        #expect(AdServicesSource.system != nil)
        #else
        // macOS and tvOS: `submitAdServicesToken()` reports `.unavailable` and sends nothing.
        #expect(AdServicesSource.system == nil)
        #endif
    }
}
