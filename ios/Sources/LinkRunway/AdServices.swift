import Foundation
#if os(iOS) && canImport(AdServices)
import AdServices
#endif

/// The outcome of `submitAdServicesToken()`.
public enum AdServicesClaim: String, Sendable {
    /// The server accepted the token during this call.
    case submitted
    /// An earlier call completed for this installation; nothing was sent.
    case alreadySubmitted
    /// Apple had not processed the token after three retries. Call again later, for example on the next launch.
    case pending
    /// No token here: tvOS, macOS, the Simulator, or a device on which AdServices returned an error.
    case unavailable
}

enum AdServicesSource {
    /// Reads Apple's attribution token. The framework does not exist on tvOS, and the claim is an iOS App Store flow.
    static var system: (@Sendable () async throws -> String)? {
        #if os(iOS) && canImport(AdServices)
        // AAAttribution needs iOS 14.3, which every OS this package deploys to already has.
        return { try AAAttribution.attributionToken() }
        #else
        return nil
        #endif
    }
}

struct AdServicesRequest: Encodable, Sendable {
    let installId: String
    let token: String
    let consent: Bool
}

extension LinkRunway {
    /// Sends Apple's AdServices attribution token to LinkRunway, which asks Apple whether this installation came
    /// from an Apple Search Ads campaign. Runs once per installation; returns nil without consent.
    @discardableResult
    public func submitAdServicesToken() async throws -> AdServicesClaim? {
        guard consent, let installId = installIdentifier else { return nil }
        if store.flag(.adServicesDone) { return .alreadySubmitted }
        guard let read = env.adServicesToken else { return .unavailable }
        if let running = claimFlight { return try await running.value }
        let task = Task { try await self.claimAppleAds(installId, read) }
        claimFlight = task
        defer { if claimFlight == task { claimFlight = nil } }
        return try await task.value
    }

    private func claimAppleAds(_ installId: String, _ read: @Sendable () async throws -> String) async throws -> AdServicesClaim? {
        let started = epoch
        // A missing token is an ordinary outcome (Simulator, restricted devices), not an error for the app to handle.
        guard let token = try? await read() else { return isCurrent(started) ? .unavailable : nil }
        guard isCurrent(started) else { return nil }
        let body = try JSONEncoder().encode(AdServicesRequest(installId: installId, token: token, consent: true))
        for attempt in 0...3 {
            let (data, status) = try await call("POST", "claims/apple-ads", body: body)
            guard isCurrent(started) else { return nil }
            if status != 202 {
                store.mark(.adServicesDone)
                return .submitted
            }
            // 202: Apple has not processed the token yet. Apple's guidance is three retries at most, five seconds
            // apart; the server may name another interval.
            let wait = (try? JSONDecoder().decode(PendingClaim.self, from: data))?.retryAfterSeconds ?? 5
            if attempt < 3 { try await env.sleep(min(max(wait, 1), 30)) }
        }
        return .pending
    }
}

private struct PendingClaim: Decodable {
    let retryAfterSeconds: Double?
}
