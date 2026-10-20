import Foundation
@testable import LinkRunway

/// The SDK's storage as a dictionary. Shared between harnesses to play a relaunch.
final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    var all: [String: Any] { locked { values } }
    func object(forKey key: String) -> Any? { locked { values[key] } }
    func set(_ value: Any?, forKey key: String) { locked { values[key] = value } }
    func removeObject(forKey key: String) { locked { values[key] = nil } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A real `UserDefaults` suite for the few tests that need one. A suite named by a path keeps its property
/// list at that path, so it lives in a temporary directory instead of the user's Preferences folder.
struct RealSuite {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LinkRunwayTests-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }

    var name: String { directory.appendingPathComponent("suite").path }
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    var contents: [String: Any] { defaults.persistentDomain(forName: name) ?? [:] }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Counts how often a closure runs, for example the AdServices token reader.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

actor FakeConversions: ConversionUpdating {
    nonisolated let isSupported: Bool
    private let accepted: [ConversionFramework]
    private var whileUpdating: (@Sendable (Int) async -> Void)?
    /// Fine values handed over, in arrival order, including calls that have not returned yet.
    private(set) var started: [Int] = []
    private(set) var updates: [ConversionUpdate] = []

    init(isSupported: Bool = true, accepted: [ConversionFramework] = [.skAdNetwork, .adAttributionKit]) {
        self.isSupported = isSupported
        self.accepted = accepted
    }

    /// Runs inside the system call, before it returns: the place to hold one update back.
    func whileUpdating(_ body: @escaping @Sendable (Int) async -> Void) { whileUpdating = body }

    func update(fineValue: Int, coarseValue: ConversionCoarseValue, lockWindow: Bool) async -> [ConversionFramework] {
        started.append(fineValue)
        await whileUpdating?(fineValue)
        updates.append(ConversionUpdate(fineValue: fineValue, coarseValue: coarseValue, lockWindow: lockWindow, frameworks: accepted))
        return accepted
    }

    var fineValues: [Int] { updates.map(\.fineValue) }
}

actor FakeAppAttest: AppAttesting {
    nonisolated let isSupported: Bool
    private(set) var generated: [String] = []
    private(set) var attestations: [(keyId: String, hash: Data)] = []
    private(set) var assertions: [(keyId: String, hash: Data)] = []
    private var attestFailures: [AppAttestFailure] = []
    private var assertFailures: [AppAttestFailure] = []

    init(isSupported: Bool = true) { self.isSupported = isSupported }

    func failNextAttestations(_ failures: [AppAttestFailure]) { attestFailures = failures }
    func failNextAssertions(_ failures: [AppAttestFailure]) { assertFailures = failures }

    func generateKey() async throws -> String {
        generated.append("key-\(generated.count + 1)")
        return generated[generated.count - 1]
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        attestations.append((keyId, clientDataHash))
        if !attestFailures.isEmpty { throw attestFailures.removeFirst() }
        return Data("attestation-object:\(keyId)".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        assertions.append((keyId, clientDataHash))
        if !assertFailures.isEmpty { throw assertFailures.removeFirst() }
        return Data("assertion:\(keyId)".utf8)
    }
}
