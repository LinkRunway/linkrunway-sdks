import Foundation

/// Where the SDK keeps its state: a `UserDefaults` suite in apps, a dictionary in unit tests.
protocol KeyValueStore: Sendable {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: KeyValueStore {}

/// The SDK's on-device state, with keys scoped to an endpoint and publishable key.
struct Store {
    enum Key: String, CaseIterable {
        case clickToken, installEvent, installSent, installId, match, matchResolved, adServicesDone, rules, highestFine, attestation,
             attestBackoff

        /// One-shot markers outlive a consent withdrawal so one installation is never counted twice.
        /// They are booleans and hold no identifier; everything else is removed.
        var isMarker: Bool { self == .installSent || self == .matchResolved || self == .adServicesDone }
    }

    let defaults: any KeyValueStore
    let scope: String

    func name(_ key: Key) -> String {
        switch key {
        // Key names from SDK 0.1, kept so an upgraded app retains its token and its INSTALL marker.
        case .clickToken: return "clickToken:\(scope)"
        case .installEvent: return "install:clickToken:\(scope)"
        case .installSent: return "install:clickToken:\(scope):sent"
        default: return "\(key.rawValue):\(scope)"
        }
    }

    func string(_ key: Key) -> String? { defaults.object(forKey: name(key)) as? String }
    func set(_ value: String?, _ key: Key) { defaults.set(value, forKey: name(key)) }
    func integer(_ key: Key) -> Int? { defaults.object(forKey: name(key)) as? Int }
    func set(_ value: Int, _ key: Key) { defaults.set(value, forKey: name(key)) }
    func flag(_ key: Key) -> Bool { defaults.object(forKey: name(key)) as? Bool ?? false }
    func mark(_ key: Key) { defaults.set(true, forKey: name(key)) }
    func clear(_ key: Key) { defaults.removeObject(forKey: name(key)) }

    func value<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (defaults.object(forKey: name(key)) as? Data).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func save<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: name(key))
    }

    /// Consent withdrawal: removes the click token, install ID, match result, rules, conversion state, and attestation.
    func wipe() {
        for key in Key.allCases where !key.isMarker { clear(key) }
    }
}
