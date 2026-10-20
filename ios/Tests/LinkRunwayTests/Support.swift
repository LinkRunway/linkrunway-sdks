import Foundation
@testable import LinkRunway

/// A scripted reply from the stub transport. `failure` throws a network error instead of answering.
struct Reply: Sendable {
    var status = 200
    var body = "{}"
    var failure: URLError.Code?

    static func json(_ body: String, status: Int = 200) -> Reply { Reply(status: status, body: body) }
    static func status(_ status: Int) -> Reply { Reply(status: status, body: #"{"message":"Request failed"}"#) }
    static let offline = Reply(failure: .notConnectedToInternet)
    static let tracked = Reply.json(#"{"id":"evt_1","attributed":true,"duplicate":false}"#)
}

struct Recorded: Sendable {
    let method: String
    let path: String
    let url: String
    let headers: [String: String]
    let body: Data?

    var json: [String: Any] { (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
    var keys: Set<String> { Set(json.keys) }
    func text(_ key: String) -> String? { json[key] as? String }
}

/// Records every request and answers from a table of path to replies. No test touches the network.
actor StubTransport: Transport {
    private let table: [String: [Reply]]
    private var whileInFlight: (@Sendable (Recorded) async -> Void)?
    private(set) var requests: [Recorded] = []

    /// Replies per path in order; the last one repeats. Unlisted paths answer 404.
    init(_ table: [String: [Reply]]) { self.table = table }

    /// Runs after a request is recorded and before it is answered: the place to change state mid-request.
    func whileInFlight(_ body: @escaping @Sendable (Recorded) async -> Void) { whileInFlight = body }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let recorded = Recorded(method: request.httpMethod ?? "GET", path: request.url?.path ?? "",
                                url: request.url?.absoluteString ?? "", headers: request.allHTTPHeaderFields ?? [:],
                                body: request.httpBody)
        let earlier = requests.filter { $0.path == recorded.path }.count
        requests.append(recorded)
        await whileInFlight?(recorded)
        guard let replies = table[recorded.path], !replies.isEmpty else { return (Data(Reply.status(404).body.utf8), 404) }
        let reply = replies[min(earlier, replies.count - 1)]
        if let failure = reply.failure { throw URLError(failure) }
        return (Data(reply.body.utf8), reply.status)
    }

    func sent(_ path: String) -> [Recorded] { requests.filter { $0.path == path } }
    var paths: [String] { requests.map(\.path) }
}

/// Waits until `condition` holds. Gives up after about five seconds, so a regression fails instead of hanging.
@discardableResult
func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<5_000 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

/// Lets other tasks run for a moment: long enough for a call to reach the point where it waits.
func breathe() async {
    for _ in 0..<50 { await Task.yield() }
}

/// Holds requests back until the test releases them.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// A clock the test moves. Sleeping advances it instead of waiting, and is recorded.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var naps: [TimeInterval] = []

    var now: Date { locked { current } }
    var sleeps: [TimeInterval] { locked { naps } }
    func advance(_ seconds: TimeInterval) { locked { current += seconds } }
    func sleep(_ seconds: TimeInterval) { locked { naps.append(seconds); current += seconds } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// One SDK instance wired to stubs. Its storage is a dictionary, so tests leave nothing on the machine.
struct Harness: Sendable {
    static let endpoint = URL(string: "https://go.example.com")!
    static let key = "lr_pk_test_0123456789abcdef"
    static let adToken = "apple-ads-attribution-token-0123456789"

    let sdk: LinkRunway
    let transport: StubTransport
    let clock: TestClock
    let conversions: FakeConversions
    let appAttest: FakeAppAttest
    let memory: MemoryStore

    init(memory: MemoryStore = MemoryStore(), clock: TestClock = TestClock(),
         conversions: FakeConversions = FakeConversions(), appAttest: FakeAppAttest = FakeAppAttest(),
         adServicesToken: (@Sendable () async throws -> String)? = { Harness.adToken },
         _ table: [String: [Reply]] = [:]) {
        let transport = StubTransport(table)
        var environment = Environment(transport: transport)
        environment.storage = { _ in memory }
        environment.now = { clock.now }
        environment.sleep = { clock.sleep($0) }
        environment.conversions = conversions
        environment.adServicesToken = adServicesToken
        environment.appAttest = appAttest
        environment.osVersion = "18.2"
        environment.language = "en-US"
        self.sdk = LinkRunway(endpoint: Harness.endpoint, publishableKey: Harness.key, suiteName: "LinkRunway", environment: environment)
        self.transport = transport
        self.clock = clock
        self.conversions = conversions
        self.appAttest = appAttest
        self.memory = memory
    }

    /// A new SDK instance over the same storage and clock: what the next launch of the app sees.
    func relaunched(conversions: FakeConversions = FakeConversions(), appAttest: FakeAppAttest = FakeAppAttest(),
                    _ table: [String: [Reply]] = [:]) -> Harness {
        Harness(memory: memory, clock: clock, conversions: conversions, appAttest: appAttest, table)
    }

    var store: Store { Store(defaults: memory, scope: "\(Harness.endpoint.absoluteString):\(Harness.key.prefix(20))") }

    /// Everything in storage, under whatever key.
    var stored: [String: Any] { memory.all }

    /// The SDK's own keys that currently hold a value.
    var storedKeys: Set<Store.Key> { Set(Store.Key.allCases.filter { stored[store.name($0)] != nil }) }
}

extension LinkRunway {
    /// Waits for the conversion updates that `track` queued, since `track` itself does not wait for them.
    func settle() async { _ = await conversionWork?.value }
}
