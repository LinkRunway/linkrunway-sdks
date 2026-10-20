import Foundation
import Testing
@testable import LinkRunway

/// The other suites replace Apple's services with fakes. These run the real ones on whatever machine runs the
/// tests (a Mac, or the iOS Simulator) and check the behaviour the documentation promises there.
/// Only the network and the storage are stubbed.
@Suite struct LiveEnvironmentTests {
    private let rules = Reply.json(#"{"id":"app_1","conversionRules":[{"event":"SIGNUP","minAmount":0,"fineValue":5,"coarseValue":"low","lockWindow":false}]}"#)

    private func live(_ table: [String: [Reply]]) -> (LinkRunway, StubTransport) {
        let transport = StubTransport(table)
        var environment = Environment(transport: transport)
        environment.storage = { _ in MemoryStore() }
        let sdk = LinkRunway(endpoint: Harness.endpoint, publishableKey: Harness.key, suiteName: "LinkRunway", environment: environment)
        return (sdk, transport)
    }

    #if os(macOS) || targetEnvironment(simulator)
    @Test func appAttestIsUnsupportedOnAMacAndInTheSimulator() async throws {
        let (sdk, transport) = live(["/v1/track": [.tracked]])
        await sdk.setConsent(true)
        #expect(AppAttestSource.system?.isSupported == false)
        #expect(await sdk.attest(appId: "app_1") == .unsupported)
        // Events still go out, without an attestation.
        #expect(try await sdk.track(type: "OPEN") != nil)
        #expect(await transport.paths == ["/v1/track"])
        #expect(await transport.requests.first?.text("attestation") == nil)
    }

    @Test func noAdServicesTokenOnAMacOrInTheSimulator() async throws {
        let (sdk, transport) = live(["/v1/claims/apple-ads": [.json("{}")]])
        await sdk.setConsent(true)
        #expect(try await sdk.submitAdServicesToken() == .unavailable)
        #expect(await transport.requests.isEmpty)
    }
    #endif

    @Test func conversionUpdatesRunOnlyOnIos() async throws {
        let (sdk, transport) = live(["/v1/mobile/config/app_1": [rules], "/v1/track": [.tracked]])
        await sdk.setConsent(true)
        let loaded = try await sdk.configureConversions(appId: "app_1")
        #expect(try await sdk.track(type: "SIGNUP") != nil)
        let update = await sdk.recordConversion(event: "SIGNUP")
        #if os(iOS)
        // The real SKAdNetwork and AdAttributionKit calls are made. With no ad attribution to update, the
        // system may accept or reject them; either way the SDK reports what it sent and carries on.
        #expect(loaded.count == 1)
        #expect(update?.fineValue == 5)
        #expect(update?.coarseValue == .low)
        #expect(await transport.paths == ["/v1/mobile/config/app_1", "/v1/track"])
        #else
        // macOS and tvOS have no conversion postbacks: the mapping is not fetched and nothing is updated.
        #expect(loaded.isEmpty)
        #expect(update == nil)
        #expect(await transport.paths == ["/v1/track"])
        #endif
    }

    @Test func thePlatformReportsWhatTheServerExpects() {
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS)
        #expect(Platform.osVersion?.range(of: #"^[0-9]{1,3}\.[0-9]{1,3}$"#, options: .regularExpression) != nil)
        #else
        // A Mac's own version would be wrong under the `ios` platform, so it is left out.
        #expect(Platform.osVersion == nil)
        #endif
        // Whatever this machine's language is, the SDK sends it only in the shape the API validates.
        if let language = Platform.language(Locale.preferredLanguages.first) {
            #expect(language.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil)
        }
    }
}
