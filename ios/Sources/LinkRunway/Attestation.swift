import CryptoKit
import Foundation

extension LinkRunway {
    /// Proves this installation to LinkRunway with App Attest and caches the server's attestation token, which
    /// `track` then attaches to events until it expires (about 24 hours). `appId` is the app's ID in the console.
    /// Never throws: when attestation does not complete, events are sent unattested. Returns nil without consent.
    @discardableResult
    public func attest(appId: String) async -> AttestationStatus? {
        attestAppId = appId
        guard consent else { return nil }
        if attestationToken(appId) != nil { return .attested }
        guard let service = env.appAttest, service.isSupported else { return .unsupported }
        if attestDisabledApp == appId { return .disabled }
        if waitingAfterFailure() { return .failed("Waiting before another attempt") }
        if let running = attestFlight { return await running.value }
        let task = Task { await self.runAttestation(appId, service) }
        attestFlight = task
        defer { if attestFlight == task { attestFlight = nil } }
        return await task.value
    }

    /// The token for an event. An expired one is renewed first when `attest(appId:)` was called in this process.
    func eventAttestation() async -> String? {
        if let token = attestationToken(nil) { return token }
        guard let appId = attestAppId else { return nil }
        _ = await attest(appId: appId)
        return attestationToken(nil)
    }

    private func attestationToken(_ appId: String?) -> String? {
        guard consent, let state = store.value(.attestation, as: AttestState.self), appId == nil || state.appId == appId,
              let token = state.token, let expiry = state.expiresAt,
              // A minute of margin for clock differences. The server ignores a stale token; it does not reject the event.
              env.now() < expiry.addingTimeInterval(-60) else { return nil }
        return token
    }

    private static let firstAttestWait: TimeInterval = 300

    /// True during the wait after a failed attempt. A wait longer than the longest backoff means the clock was set
    /// back, and is ignored.
    private func waitingAfterFailure() -> Bool {
        guard let backoff = store.value(.attestBackoff, as: AttestBackoff.self) else { return false }
        let remaining = backoff.retryAfter.timeIntervalSince(env.now())
        return remaining > 0 && remaining <= Self.firstAttestWait * 64
    }

    private func runAttestation(_ appId: String, _ service: any AppAttesting) async -> AttestationStatus? {
        let started = epoch
        do {
            do {
                try await exchange(appId, service, started)
            } catch AppAttestFailure.invalidKey {
                // The Secure Enclave lost this key (reinstall, migration, restore) or the server does not know it:
                // start over once with a new key.
                guard isCurrent(started) else { return nil }
                store.clear(.attestation)
                try await exchange(appId, service, started)
            }
            store.clear(.attestBackoff)
            return .attested
        } catch AppAttestFailure.disabled {
            // Attestation is off for this app: not a failure, so no wait is stored and nothing is retried.
            guard isCurrent(started) else { return nil }
            attestDisabledApp = appId
            return .disabled
        } catch {
            guard isCurrent(started) else { return nil }
            // The wait doubles from five minutes to about five hours and is stored, so a server that keeps refusing
            // registrations cannot turn every event, or every launch, into a new key and a new request to Apple.
            let failures = (store.value(.attestBackoff, as: AttestBackoff.self)?.failures ?? 0) + 1
            let wait = Self.firstAttestWait * Double(1 << min(failures - 1, 6))
            store.save(AttestBackoff(failures: failures, retryAfter: env.now().addingTimeInterval(wait)), .attestBackoff)
            return .failed(String(String(describing: error).prefix(200)))
        }
    }

    /// One challenge round: register a new key with an attestation, or renew with an assertion from a registered key.
    private func exchange(_ appId: String, _ service: any AppAttesting, _ started: Int) async throws {
        var state = store.value(.attestation, as: AttestState.self).flatMap { $0.appId == appId ? $0 : nil }
            ?? AttestState(appId: appId)
        // The challenge comes first: when the server declines (an unknown app, a revoked API key) no key is created.
        let challenge: AttestChallenge
        do {
            challenge = try await post("attest/challenge", AttestChallengeRequest(appId: appId))
        } catch LinkRunwayError.server(409, _) {
            throw AppAttestFailure.disabled
        }
        // The server verifies the hash of the challenge text exactly as sent, so it is never decoded here.
        let hash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        if state.keyId == nil {
            let created = try await service.generateKey()
            guard isCurrent(started) else { throw LinkRunwayError.consentRequired }
            state.keyId = created
            store.save(state, .attestation)
        }
        guard let keyId = state.keyId else { throw LinkRunwayError.invalidResponse }
        let issued: AttestationResponse
        if state.registered {
            let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
            do {
                issued = try await post("attest/apple/assert", AppleAssertRequest(
                    appId: appId, challengeId: challenge.challengeId, keyId: keyId, assertion: assertion.base64EncodedString()))
            } catch LinkRunwayError.server(404, _) {
                // The server does not know this key: the one answer that replaces it. Any other rejection (a spent
                // or expired challenge, a used counter) says nothing against the key, so it is kept, and the next
                // attempt asserts again for a fresh challenge. Apple limits how many keys a device may create.
                throw AppAttestFailure.invalidKey
            }
        } else {
            let object: Data
            do {
                object = try await attestKey(service, keyId, hash)
            } catch AppAttestFailure.serverUnavailable {
                // Apple's service was unreachable. The key is still unattested, so it is kept for the next attempt.
                throw AppAttestFailure.serverUnavailable
            } catch {
                // Apple's guidance for any other attestKey error: discard the key and create a new one.
                if isCurrent(started) { store.clear(.attestation) }
                throw error
            }
            // Apple attests a key only once. From here on the key counts as registered whatever the server answers,
            // even none: the next attempt asserts with it, and only a 404 to that assertion replaces it.
            guard isCurrent(started) else { throw LinkRunwayError.consentRequired }
            state.registered = true
            store.save(state, .attestation)
            issued = try await post("attest/apple/register", AppleAttestRequest(
                appId: appId, challengeId: challenge.challengeId, keyId: keyId, attestation: object.base64EncodedString()))
        }
        guard isCurrent(started) else { throw LinkRunwayError.consentRequired }
        state.token = issued.attestation
        // A new token is used for at least five minutes, whatever its expiry says: a device clock that runs
        // ahead of the server's must not turn every event into a renewal.
        state.expiresAt = max(Timestamp.date(issued.expiresAt) ?? env.now().addingTimeInterval(3600),
                              env.now().addingTimeInterval(360))
        store.save(state, .attestation)
    }

    private func attestKey(_ service: any AppAttesting, _ keyId: String, _ hash: Data) async throws -> Data {
        // Apple asks for the same key and the same hash when its service is unreachable, which keeps the
        // device's risk metric intact, so the retries happen here while the challenge is still valid.
        for attempt in 0..<2 {
            do {
                return try await service.attestKey(keyId, clientDataHash: hash)
            } catch AppAttestFailure.serverUnavailable {
                try await env.sleep(Double(attempt + 1))
            }
        }
        return try await service.attestKey(keyId, clientDataHash: hash)
    }
}
