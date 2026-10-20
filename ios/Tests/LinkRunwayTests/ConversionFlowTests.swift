import Foundation
import Testing
@testable import LinkRunway

/// A conversion mapping as the API serves it, and the updates it should produce.
enum Mapping {
    static let config = "/v1/mobile/config/app_1"
    static let track = "/v1/track"
    static let reply = Reply.json("""
    {"id":"app_1","conversionRules":[
      {"event":"INSTALL","minAmount":0,"fineValue":0,"coarseValue":"low","lockWindow":false},
      {"event":"SIGNUP","minAmount":0,"fineValue":5,"coarseValue":"low","lockWindow":false},
      {"event":"CUSTOM","name":"level_10","minAmount":0,"fineValue":9,"coarseValue":"medium","lockWindow":false},
      {"event":"PURCHASE","minAmount":0,"fineValue":20,"coarseValue":"medium","lockWindow":false},
      {"event":"PURCHASE","minAmount":5000,"fineValue":45,"coarseValue":"high","lockWindow":true}
    ]}
    """)

    static func update(_ fine: Int, _ coarse: ConversionCoarseValue, lock: Bool = false,
                       frameworks: [ConversionFramework] = [.skAdNetwork, .adAttributionKit]) -> ConversionUpdate {
        ConversionUpdate(fineValue: fine, coarseValue: coarse, lockWindow: lock, frameworks: frameworks)
    }
}

private let config = Mapping.config, track = Mapping.track, mapping = Mapping.reply
private func update(_ fine: Int, _ coarse: ConversionCoarseValue, lock: Bool = false,
                    frameworks: [ConversionFramework] = [.skAdNetwork, .adAttributionKit]) -> ConversionUpdate {
    Mapping.update(fine, coarse, lock: lock, frameworks: frameworks)
}

@Suite struct ConversionFlowTests {
    @Test func theMappingIsFetchedOnceAndRefreshedAtMostDaily() async throws {
        let h = Harness([config: [mapping], track: [.tracked]])
        await h.sdk.setConsent(true)

        let rules = try await h.sdk.configureConversions(appId: "app_1")
        #expect(rules.map(\.fineValue) == [0, 5, 9, 20, 45])
        #expect(rules[2].name == "level_10")
        #expect(rules[4].lockWindow)

        // Configuring again and sending events within a day reuses the stored mapping.
        try await h.sdk.configureConversions(appId: "app_1")
        try await h.sdk.track(type: "SIGNUP")
        h.clock.advance(86_399)
        try await h.sdk.configureConversions(appId: "app_1")
        await h.sdk.recordConversion(event: "PURCHASE", amount: 100)
        #expect(await h.transport.sent(config).count == 1)

        h.clock.advance(1)
        try await h.sdk.configureConversions(appId: "app_1")
        #expect(await h.transport.sent(config).count == 2)
    }

    @Test func aRelaunchWithinADayUsesTheStoredMapping() async throws {
        let h = Harness([config: [mapping]])
        await h.sdk.setConsent(true)
        let first = try await h.sdk.configureConversions(appId: "app_1")

        let next = h.relaunched([config: [mapping]])
        await next.sdk.setConsent(true)
        #expect(try await next.sdk.configureConversions(appId: "app_1") == first)
        #expect(await next.transport.requests.isEmpty)
        // A different app's mapping is never reused.
        _ = try? await next.sdk.configureConversions(appId: "app_2")
        #expect(await next.transport.paths == ["/v1/mobile/config/app_2"])
    }

    @Test func everySuccessfulEventUpdatesTheConversionValue() async throws {
        let h = Harness([config: [mapping], track: [.tracked]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")

        try await h.sdk.install()
        try await h.sdk.track(type: "OPEN")
        try await h.sdk.track(type: "SIGNUP")
        try await h.sdk.track(type: "CUSTOM", name: "tutorial")
        try await h.sdk.track(type: "CUSTOM", name: "level_10")
        await h.sdk.settle()
        #expect(await h.conversions.updates == [update(0, .low), update(5, .low), update(9, .medium)])
        #expect(await h.transport.sent(track).count == 5)
        #expect(h.store.integer(.highestFine) == 9)
    }

    @Test func recordConversionUpdatesAppleAndSendsNothingToLinkRunway() async throws {
        let h = Harness([config: [mapping]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        let before = await h.transport.requests.count

        // A purchase the backend reports with a server key: the app only knows the amount.
        #expect(await h.sdk.recordConversion(event: "PURCHASE", amount: 1_999) == update(20, .medium))
        #expect(await h.sdk.recordConversion(event: "purchase", amount: 7_500) == update(45, .high, lock: true))
        #expect(await h.sdk.recordConversion(event: "CUSTOM", name: "level_10") == nil)
        #expect(await h.sdk.recordConversion(event: "REFUND", amount: 7_500) == nil)
        #expect(await h.transport.requests.count == before)
        #expect(await h.conversions.updates == [update(20, .medium), update(45, .high, lock: true)])
    }

    @Test func theValueNeverGoesDownAndIsRememberedAcrossLaunches() async throws {
        let h = Harness([config: [mapping], track: [.tracked]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        await h.sdk.recordConversion(event: "PURCHASE", amount: 9_000)
        try await h.sdk.track(type: "SIGNUP")
        #expect(await h.sdk.recordConversion(event: "PURCHASE", amount: 100) == nil)
        await h.sdk.settle()
        #expect(await h.conversions.fineValues == [45])

        let next = h.relaunched([config: [mapping], track: [.tracked]])
        await next.sdk.setConsent(true)
        try await next.sdk.configureConversions(appId: "app_1")
        try await next.sdk.track(type: "SIGNUP")
        #expect(await next.sdk.recordConversion(event: "PURCHASE", amount: 100) == nil)
        #expect(await next.conversions.updates.isEmpty)
        // The same level may be sent again; a lower one never is.
        #expect(await next.sdk.recordConversion(event: "PURCHASE", amount: 6_000)?.fineValue == 45)
        #expect(await next.conversions.fineValues == [45])
    }

    @Test func nothingHappensWithoutConsentOrWherePostbacksDoNotExist() async throws {
        let off = Harness([config: [mapping]])
        #expect(try await off.sdk.configureConversions(appId: "app_1").isEmpty)
        #expect(await off.sdk.recordConversion(event: "SIGNUP") == nil)
        #expect(await off.transport.requests.isEmpty)
        #expect(off.stored.isEmpty)

        // tvOS and macOS: the mapping is not even fetched.
        let tv = Harness(conversions: FakeConversions(isSupported: false), [config: [mapping], track: [.tracked]])
        await tv.sdk.setConsent(true)
        #expect(try await tv.sdk.configureConversions(appId: "app_1").isEmpty)
        try await tv.sdk.track(type: "SIGNUP")
        #expect(await tv.sdk.recordConversion(event: "PURCHASE", amount: 9_000) == nil)
        #expect(await tv.transport.paths == [track])
        #expect(await tv.conversions.updates.isEmpty)
        #expect(tv.storedKeys == [.installId])
    }

    @Test func configuringBeforeConsentAppliesOnceConsentIsGiven() async throws {
        let h = Harness([config: [mapping], track: [.tracked]])
        #expect(try await h.sdk.configureConversions(appId: "app_1").isEmpty)
        await h.sdk.setConsent(true)
        try await h.sdk.track(type: "SIGNUP")
        await h.sdk.settle()
        // The event went out first; the mapping was fetched for it afterwards.
        #expect(await h.transport.paths == [track, config])
        #expect(await h.conversions.updates == [update(5, .low)])
    }

    @Test func anUnreachableMappingDoesNotBlockEventsOrRefetchOnEveryOne() async throws {
        let h = Harness([config: [.offline, .offline, .offline, .status(503), .status(503), .status(503), mapping],
                         track: [.tracked]])
        await h.sdk.setConsent(true)
        await #expect(throws: URLError.self) { try await h.sdk.configureConversions(appId: "app_1") }
        #expect(await h.transport.sent(config).count == 3)

        // Within five minutes of a failure, events are sent and no further fetch is attempted.
        #expect(try await h.sdk.track(type: "SIGNUP") != nil)
        #expect(try await h.sdk.track(type: "SIGNUP") != nil)
        await h.sdk.settle()
        #expect(await h.transport.sent(config).count == 3)
        #expect(await h.conversions.updates.isEmpty)

        h.clock.advance(300)
        #expect(try await h.sdk.track(type: "SIGNUP") != nil)
        await h.sdk.settle()
        #expect(await h.transport.sent(config).count == 6)
        #expect(await h.conversions.updates.isEmpty)

        h.clock.advance(300)
        #expect(try await h.sdk.track(type: "SIGNUP") != nil)
        await h.sdk.settle()
        #expect(await h.transport.sent(config).count == 7)
        #expect(await h.conversions.updates == [update(5, .low)])
    }

    @Test func aStaleMappingKeepsWorkingWhileARefreshFails() async throws {
        let h = Harness([config: [mapping, .status(500)]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        h.clock.advance(2 * 86_400)

        #expect(try await h.sdk.configureConversions(appId: "app_1").count == 5)
        #expect(await h.sdk.recordConversion(event: "SIGNUP") == update(5, .low))
        // One failed refresh (three attempts), not one per call.
        #expect(await h.transport.sent(config).count == 4)
    }

    @Test func aFailedEventDoesNotUpdateTheConversionValue() async throws {
        let h = Harness([config: [mapping], track: [.status(400)]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        await #expect(throws: LinkRunwayError.self) { try await h.sdk.track(type: "SIGNUP") }
        await h.sdk.settle()
        #expect(await h.conversions.updates.isEmpty)
        #expect(h.store.integer(.highestFine) == nil)
    }
}
