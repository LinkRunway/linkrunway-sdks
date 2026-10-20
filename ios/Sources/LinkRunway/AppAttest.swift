import Foundation
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// The outcome of `attest(appId:)`.
public enum AttestationStatus: Sendable, Equatable {
    /// A server-issued attestation token is cached and is attached to events until it expires.
    case attested
    /// App Attest is not available here: the Simulator, a Mac, or most app extensions. Events are sent unattested.
    case unsupported
    /// The workspace owner turned attestation off for this app. Nothing more is requested until the app is next
    /// launched, and events are sent unattested.
    case disabled
    /// The attempt did not complete. Events are sent unattested and the SDK waits before trying again:
    /// five minutes after the first failure, doubling up to about five hours.
    case failed(String)
}

/// The App Attest failures the SDK reacts to; anything else passes through unchanged.
enum AppAttestFailure: Error, Equatable {
    /// The key cannot be used: already attested, or lost to a reinstall, device migration, or restore.
    case invalidKey
    /// Apple's attestation service could not be reached.
    case serverUnavailable
    /// The challenge was answered 409: the owner turned attestation off for this app.
    case disabled
}

protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

enum AppAttestSource {
    static var system: (any AppAttesting)? {
        #if canImport(DeviceCheck)
        return SystemAppAttest()
        #else
        return nil
        #endif
    }
}

#if canImport(DeviceCheck)
struct SystemAppAttest: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await mapped { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await mapped { try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash) }
    }

    private func mapped<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as DCError where error.code == .invalidKey {
            throw AppAttestFailure.invalidKey
        } catch let error as DCError where error.code == .serverUnavailable {
            throw AppAttestFailure.serverUnavailable
        }
    }
}
#endif

struct AttestChallengeRequest: Encodable, Sendable {
    let appId: String
}
struct AttestChallenge: Decodable, Sendable {
    let challengeId: String
    let challenge: String
}
struct AppleAttestRequest: Encodable, Sendable {
    let appId: String
    let challengeId: String
    let keyId: String
    let attestation: String
}
struct AppleAssertRequest: Encodable, Sendable {
    let appId: String
    let challengeId: String
    let keyId: String
    let assertion: String
}
struct AttestationResponse: Decodable, Sendable {
    let attestation: String
    let expiresAt: String
}

/// What the SDK keeps about App Attest: the key's identifier, whether the server has it, and the current token.
struct AttestState: Codable, Sendable {
    var appId: String
    var keyId: String?
    var registered = false
    var token: String?
    var expiresAt: Date?
}

/// The wait before the next App Attest attempt after one failed. It is stored, so a server that keeps refusing
/// registrations does not get a new Secure Enclave key on every launch.
struct AttestBackoff: Codable, Sendable {
    let failures: Int
    let retryAfter: Date
}
