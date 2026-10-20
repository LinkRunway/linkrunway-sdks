import Foundation
import Testing
@testable import LinkRunway

private let path = "/v1/installs/match"
private let matched = Reply.json("""
{"matched":true,"method":"PROBABILISTIC","clickId":"clk_1","clickToken":"tok_match","path":"/products/42",
 "url":"https://example.com/products/42","metadata":{"campaign":"spring","discount":10,"vip":true,"note":null}}
""")
private let unmatched = Reply.json(#"{"matched":false,"method":"NONE"}"#)

@Suite struct MatchingTests {
    @Test func aMatchReturnsTheDeepLinkAndSavesTheClickToken() async throws {
        let h = Harness([path: [matched], "/v1/track": [.tracked]])
        await h.sdk.setConsent(true)
        #expect(await h.sdk.attributionToken() == nil)

        let match = try #require(try await h.sdk.matchInstall())
        #expect(match.matched)
        #expect(match.method == .probabilistic)
        #expect(match.clickId == "clk_1")
        #expect(match.path == "/products/42")
        #expect(match.url == "https://example.com/products/42")
        #expect(match.metadata == ["campaign": .string("spring"), "discount": .number(10), "vip": .boolean(true), "note": .null])

        // Saved as `open(_:)` saves it: later events carry it.
        #expect(await h.sdk.attributionToken() == "tok_match")
        try await h.sdk.track(type: "INSTALL")
        #expect(await h.transport.sent("/v1/track").first?.text("clickToken") == "tok_match")
    }

    @Test func theAnswerIsResolvedOncePerInstallation() async throws {
        let h = Harness([path: [matched]])
        await h.sdk.setConsent(true)
        let first = try await h.sdk.matchInstall()
        let second = try await h.sdk.matchInstall()
        let third = try await h.sdk.matchInstall()
        #expect(first == second)
        #expect(first == third)
        #expect(await h.transport.sent(path).count == 1)

        // The next launch reads the stored answer and asks nothing.
        let next = h.relaunched([path: [unmatched]])
        await next.sdk.setConsent(true)
        #expect(try await next.sdk.matchInstall() == first)
        #expect(await next.sdk.attributionToken() == "tok_match")
        #expect(await next.transport.requests.isEmpty)
    }

    @Test func theStoredAnswerDoesNotRepeatTheClickToken() async throws {
        let h = Harness([path: [matched]])
        await h.sdk.setConsent(true)
        try await h.sdk.matchInstall()
        let cached = try #require(h.stored[h.store.name(.match)] as? Data)
        #expect(!String(decoding: cached, as: UTF8.self).contains("tok_match"))
        #expect(h.store.string(.clickToken) == "tok_match")
    }

    @Test func concurrentCallsShareOneRequest() async throws {
        let h = Harness([path: [matched]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        let gate = Gate()
        await h.transport.whileInFlight { _ in await gate.pass() }

        async let first = sdk.matchInstall()
        // Wait until the first request is on the wire, then start two more calls behind it.
        #expect(await eventually { await !h.transport.requests.isEmpty })
        async let second = sdk.matchInstall()
        async let third = sdk.matchInstall()
        await breathe()
        await gate.open()

        let results = try await [first, second, third]
        #expect(results.allSatisfy { $0?.clickId == "clk_1" })
        #expect(await h.transport.sent(path).count == 1)
    }

    @Test func noMatchIsAnAnswerToo() async throws {
        let h = Harness([path: [unmatched]])
        await h.sdk.setConsent(true)
        let match = try #require(try await h.sdk.matchInstall())
        #expect(!match.matched)
        #expect(match.method == .unmatched)
        #expect(match.path == nil)
        #expect(match.metadata.isEmpty)
        #expect(await h.sdk.attributionToken() == nil)
        #expect(try await h.sdk.matchInstall() == match)
        #expect(await h.transport.sent(path).count == 1)
    }

    @Test func anUnmatchedAnswerLeavesAnExistingTokenAlone() async throws {
        let h = Harness([path: [unmatched]])
        await h.sdk.setConsent(true)
        try await h.sdk.open(URL(string: "myapp://open?lr_token=tok_direct")!)
        try await h.sdk.matchInstall()
        #expect(await h.sdk.attributionToken() == "tok_direct")

        // Even if an unmatched answer carried a token, it would not be used.
        let stray = Harness([path: [.json(#"{"matched":false,"method":"PROBABILISTIC","clickToken":"tok_stray"}"#)]])
        await stray.sdk.setConsent(true)
        #expect(try await stray.sdk.matchInstall()?.method == .probabilistic)
        #expect(await stray.sdk.attributionToken() == nil)
    }

    @Test func aFailedRequestIsNotStoredAndCanBeRetried() async throws {
        let h = Harness([path: [.status(500), .offline, .status(503), matched]])
        await h.sdk.setConsent(true)
        // Three attempts with the usual backoff, then the error reaches the app.
        await #expect(throws: LinkRunwayError.self) { try await h.sdk.matchInstall() }
        #expect(await h.transport.sent(path).count == 3)
        #expect(h.clock.sleeps == [0.3, 0.6])
        #expect(h.storedKeys == [.installId])

        // The same install ID is sent again, so the server gives the answer it stored.
        #expect(try await h.sdk.matchInstall()?.matched == true)
        let sent = await h.transport.sent(path)
        #expect(sent.count == 4)
        #expect(Set(sent.map { $0.text("installId") }).count == 1)
    }

    @Test func aRejectedRequestIsNotRetried() async throws {
        let h = Harness([path: [.status(400)]])
        await h.sdk.setConsent(true)
        do {
            try await h.sdk.matchInstall()
            Issue.record("A 400 should be thrown")
        } catch LinkRunwayError.server(let status, _) {
            #expect(status == 400)
        }
        #expect(await h.transport.sent(path).count == 1)
        #expect(h.clock.sleeps.isEmpty)
    }

    @Test func aMethodFromANewerServerStillDecodes() async throws {
        let h = Harness([path: [.json(#"{"matched":true,"method":"QR_CODE","clickId":"clk_9","path":"/x"}"#)]])
        await h.sdk.setConsent(true)
        let match = try #require(try await h.sdk.matchInstall())
        #expect(match.matched)
        #expect(match.method == .unknown)
        #expect(match.path == "/x")
        // A match without a token changes nothing about attribution.
        #expect(await h.sdk.attributionToken() == nil)
    }

    @Test func unusualLocalesAreLeftOutRatherThanFailingTheRequest() async throws {
        let transport = StubTransport([path: [unmatched]])
        var environment = Environment(transport: transport)
        environment.storage = { _ in MemoryStore() }
        environment.osVersion = nil
        environment.language = Platform.language("en_US@calendar=gregorian")
        let sdk = LinkRunway(endpoint: Harness.endpoint, publishableKey: Harness.key, suiteName: "LinkRunway", environment: environment)
        await sdk.setConsent(true)
        try await sdk.matchInstall()
        #expect(await transport.requests.first?.keys == ["installId", "platform", "consent"])
    }
}
