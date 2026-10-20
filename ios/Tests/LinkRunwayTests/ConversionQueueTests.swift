import Foundation
import Testing
@testable import LinkRunway

private let config = Mapping.config, track = Mapping.track, mapping = Mapping.reply
private func update(_ fine: Int, _ coarse: ConversionCoarseValue, lock: Bool = false,
                    frameworks: [ConversionFramework] = [.skAdNetwork, .adAttributionKit]) -> ConversionUpdate {
    Mapping.update(fine, coarse, lock: lock, frameworks: frameworks)
}

/// How conversion updates are handed to Apple: after the event, one at a time, never out of order.
@Suite struct ConversionQueueTests {
    @Test func trackDoesNotWaitForASlowConversionUpdate() async throws {
        let conversions = FakeConversions()
        let gate = Gate()
        await conversions.whileUpdating { _ in await gate.pass() }
        let h = Harness(conversions: conversions, [config: [mapping], track: [.tracked]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        try await sdk.configureConversions(appId: "app_1")

        // The system call is held, as the first SKAdNetwork call can be for seconds.
        let returned = Counter()
        let event = Task {
            _ = try? await sdk.track(type: "SIGNUP")
            returned.increment()
        }
        #expect(await eventually { await !conversions.started.isEmpty })
        // The event has returned to the app although its conversion update has not finished.
        #expect(await eventually { returned.value == 1 })
        #expect(await conversions.updates.isEmpty)
        await gate.open()
        await event.value
        await sdk.settle()
        #expect(await conversions.updates == [update(5, .low)])
    }

    @Test func updatesReachTheSystemOneAtATimeInOrder() async throws {
        let conversions = FakeConversions()
        let gate = Gate()
        await conversions.whileUpdating { fine in
            if fine == 20 { await gate.pass() }
        }
        let h = Harness(conversions: conversions, [config: [mapping], track: [.tracked]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        try await sdk.configureConversions(appId: "app_1")

        async let small = sdk.recordConversion(event: "PURCHASE", amount: 100)
        #expect(await eventually { await !conversions.started.isEmpty })
        // The small purchase is still inside the system call when a signup and a large purchase arrive.
        async let signup = sdk.recordConversion(event: "SIGNUP")
        await breathe()
        async let large = sdk.recordConversion(event: "PURCHASE", amount: 9_000)
        await breathe()
        // Both wait their turn: two calls in flight could reach Apple in either order.
        #expect(await conversions.started == [20])
        await gate.open()

        #expect(await small?.fineValue == 20)
        #expect(await signup == nil)
        #expect(await large?.fineValue == 45)
        // The signup's lower value was dropped; the rest arrived in the order they were requested.
        #expect(await conversions.fineValues == [20, 45])
    }

    @Test func aValueTheSystemRejectedIsStillTheHighWaterMark() async throws {
        let h = Harness(conversions: FakeConversions(accepted: []), [config: [mapping]])
        await h.sdk.setConsent(true)
        try await h.sdk.configureConversions(appId: "app_1")
        // What the Simulator does: the call is made and no framework accepts it.
        #expect(await h.sdk.recordConversion(event: "PURCHASE", amount: 100) == update(20, .medium, frameworks: []))
        #expect(await h.sdk.recordConversion(event: "SIGNUP") == nil)
    }

    @Test func theLiveUpdaterIsOffOutsideIos() async {
        #if os(iOS)
        #expect(SystemConversions().isSupported)
        #else
        #expect(!SystemConversions().isSupported)
        #expect(await SystemConversions().update(fineValue: 5, coarseValue: .low, lockWindow: false).isEmpty)
        #endif
    }

    @Test func updatesQueuedBeforeAWithdrawalAreDropped() async throws {
        let conversions = FakeConversions()
        let gate = Gate()
        await conversions.whileUpdating { fine in
            if fine == 20 { await gate.pass() }
        }
        let h = Harness(conversions: conversions, [config: [mapping], track: [.tracked]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        try await sdk.configureConversions(appId: "app_1")

        async let held = sdk.recordConversion(event: "PURCHASE", amount: 100)
        #expect(await eventually { await !conversions.started.isEmpty })
        let first = await sdk.conversionWork
        async let waiting = sdk.recordConversion(event: "PURCHASE", amount: 9_000)
        // The second update is queued behind the first before consent is withdrawn and given again.
        #expect(await eventually { await sdk.conversionWork != first })
        await sdk.setConsent(false)
        await sdk.setConsent(true)
        await gate.open()

        // The first was already with Apple; the second belonged to the withdrawn consent.
        #expect(await held?.fineValue == 20)
        #expect(await waiting == nil)
        #expect(await conversions.started == [20])
        #expect(h.storedKeys == [.installId])
    }

    @Test func aLockingUpdateReachesAdAttributionKitFirst() {
        #expect(SystemConversions.order(lockWindow: false) == [.skAdNetwork, .adAttributionKit])
        #expect(SystemConversions.order(lockWindow: true) == [.adAttributionKit, .skAdNetwork])
    }

    @Test func anEventAnsweredAfterAWithdrawalUpdatesNothing() async throws {
        let h = Harness([config: [mapping], track: [.tracked]])
        let sdk = h.sdk
        await sdk.setConsent(true)
        try await sdk.configureConversions(appId: "app_1")
        // Consent is withdrawn and given again while the event is on its way.
        await h.transport.whileInFlight { request in
            guard request.path == track else { return }
            await sdk.setConsent(false)
            await sdk.setConsent(true)
        }
        #expect(try await sdk.track(type: "SIGNUP") != nil)
        await sdk.settle()
        #expect(await h.conversions.updates.isEmpty)
        #expect(await h.transport.paths == [config, track])
    }
}
