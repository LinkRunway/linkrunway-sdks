import Foundation
public struct ResolvedLink: Decodable, Sendable {
    public let clickId: String
    public let clickToken: String?
    public let metadata: [String: MetadataValue]
    public let path: String
    public let url: String
}
public struct SharedLink: Decodable, Sendable {
    public let shareId: String
    public let url: String
}
public struct TrackingResult: Decodable, Sendable {
    public let id: String
    public let attributed: Bool
    public let duplicate: Bool
}
public enum LinkRunwayError: Error {
    case consentRequired, invalidEvent, invalidResponse
    case server(Int, String)
}
struct ResolveRequest: Encodable, Sendable {
    let url: String
    let consent: Bool
    let platform: String
}
struct EventRequest: Encodable, Sendable {
    let eventId: String
    let type: String
    let name: String?
    let clickToken: String?
    let externalUserId: String?
    let metadata: [String: String]
    let consent: Bool
    let occurredAt: String
    let installId: String?
    let attestation: String?
}
struct ShareRequest: Encodable, Sendable {
    let linkId: String
    let externalUserId: String?
    let channel: String
}

public struct ReferralCode: Decodable, Sendable {
    public let code: String
    public let expiresAt: String
}
struct ReferralCreateRequest: Encodable, Sendable {
    let clickToken: String
    let consent: Bool
}
struct ReferralClaimRequest: Encodable, Sendable {
    let code: String
    let claimId: String
    let consent: Bool
}
public enum MetadataValue: Codable, Sendable, Equatable {
    case string(String), number(Double), boolean(Bool), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else { self = .number(try value.decode(Double.self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .boolean(let boolean): try value.encode(boolean)
        case .null: try value.encodeNil()
        }
    }
}
