import Foundation
import Testing
@testable import LinkRunway

/// The other suites keep state in a dictionary. This one checks that a `UserDefaults` suite behaves the same.
@Suite struct StoreTests {
    static let scope = "https://go.example.com:lr_pk_test_0123456789"

    @Test func userDefaultsAndTheTestStoreBehaveAlike() {
        let suite = RealSuite()
        defer { suite.remove() }
        let backings: [any KeyValueStore] = [DefaultsStore(suite.defaults), MemoryStore()]
        for backing in backings {
            let store = Store(defaults: backing, scope: Self.scope)
            #expect(store.string(.clickToken) == nil)
            #expect(store.integer(.highestFine) == nil)
            #expect(!store.flag(.installSent))
            #expect(store.value(.rules, as: CachedRules.self) == nil)

            store.set("tok_1", .clickToken)
            store.set("0b5c2a44-7a43-4d0e-9c0f-1d2e3f4a5b6c", .installId)
            store.set(0, .highestFine)
            store.mark(.installSent)
            store.mark(.matchResolved)
            store.save(CachedRules(appId: "app_1", fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), rules: []), .rules)
            store.save(AttestState(appId: "app_1", keyId: "key-1", registered: true, token: "token-1",
                                   expiresAt: Date(timeIntervalSince1970: 1_800_086_400)), .attestation)

            #expect(store.string(.clickToken) == "tok_1")
            // Zero is a value, not an absence: an install rule with fine value 0 has been sent.
            #expect(store.integer(.highestFine) == 0)
            store.set(63, .highestFine)
            #expect(store.integer(.highestFine) == 63)
            #expect(store.flag(.installSent))
            #expect(!store.flag(.adServicesDone))
            #expect(store.value(.rules, as: CachedRules.self)?.appId == "app_1")
            let attest = store.value(.attestation, as: AttestState.self)
            #expect(attest?.keyId == "key-1")
            #expect(attest?.registered == true)
            #expect(attest?.expiresAt == Date(timeIntervalSince1970: 1_800_086_400))
            // A value of another type reads as absent instead of being coerced.
            #expect(store.string(.highestFine) == nil)
            #expect(store.value(.clickToken, as: CachedRules.self) == nil)

            store.set(nil, .clickToken)
            #expect(store.string(.clickToken) == nil)
            store.wipe()
            // Only the markers that were set remain.
            #expect(Store.Key.allCases.filter { backing.object(forKey: store.name($0)) != nil } == [.installSent, .matchResolved])
            #expect(store.flag(.installSent) && store.flag(.matchResolved))
        }
        #expect(Set(suite.contents.keys) == ["install:clickToken:\(Self.scope):sent", "matchResolved:\(Self.scope)"])
    }

    @Test func keyNamesAreScopedAndKeepTheNamesSdkOneUsed() {
        let store = Store(defaults: MemoryStore(), scope: Self.scope)
        #expect(store.name(.clickToken) == "clickToken:\(Self.scope)")
        #expect(store.name(.installEvent) == "install:clickToken:\(Self.scope)")
        #expect(store.name(.installSent) == "install:clickToken:\(Self.scope):sent")
        let names = Store.Key.allCases.map(store.name)
        #expect(Set(names).count == Store.Key.allCases.count)
        #expect(names.allSatisfy { $0.contains(Self.scope) })
        // Two SDK instances for different endpoints or keys never read each other's values.
        let other = Store(defaults: MemoryStore(), scope: "https://go.example.org:lr_pk_test_0123456789")
        #expect(Set(names).isDisjoint(with: Store.Key.allCases.map(other.name)))
        #expect(Store.Key.allCases.filter(\.isMarker) == [.installSent, .matchResolved, .adServicesDone])
    }
}
