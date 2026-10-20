import Foundation

public enum ConversionCoarseValue: String, Codable, Sendable {
    case low, medium, high
}

/// One row of the app's conversion mapping, as configured in the LinkRunway console.
public struct ConversionRule: Codable, Sendable, Equatable {
    /// An event type such as `INSTALL`, `SIGNUP`, `PURCHASE`, or `CUSTOM`.
    public let event: String
    /// When set, the rule applies only to events with this custom name.
    public let name: String?
    /// The smallest amount, in minor units, the rule applies to.
    public let minAmount: Int
    /// Apple's fine conversion value, 0 through 63.
    public let fineValue: Int
    public let coarseValue: ConversionCoarseValue
    public let lockWindow: Bool
}

extension ConversionRule {
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        event = try values.decode(String.self, forKey: .event)
        let label = try values.decodeIfPresent(String.self, forKey: .name)
        name = label?.isEmpty == false ? label : nil
        minAmount = try values.decodeIfPresent(Int.self, forKey: .minAmount) ?? 0
        fineValue = try values.decode(Int.self, forKey: .fineValue)
        coarseValue = try values.decode(ConversionCoarseValue.self, forKey: .coarseValue)
        lockWindow = try values.decodeIfPresent(Bool.self, forKey: .lockWindow) ?? false
        guard (0...63).contains(fineValue) else {
            throw DecodingError.dataCorruptedError(forKey: .fineValue, in: values, debugDescription: "Fine values run from 0 to 63")
        }
    }
}

public enum ConversionFramework: String, Sendable {
    case skAdNetwork = "SKAdNetwork", adAttributionKit = "AdAttributionKit"
}

/// What the SDK handed to Apple's conversion APIs for one event.
public struct ConversionUpdate: Sendable, Equatable {
    public let fineValue: Int
    public let coarseValue: ConversionCoarseValue
    public let lockWindow: Bool
    /// The frameworks that accepted the call. Empty when the system rejected it, for example in the Simulator.
    public let frameworks: [ConversionFramework]
}

/// Pure rule selection. Nothing here touches storage, the network, or Apple frameworks.
enum ConversionRules {
    /// The rule an event maps to. A rule applies when its event type equals the event's, its name (if it has one)
    /// equals the event's name, and its `minAmount` does not exceed the amount. Among those the highest `minAmount`
    /// wins; on equal thresholds a named rule beats an unnamed one, then the higher fine value, then the earlier rule.
    static func best(_ rules: [ConversionRule], event: String, name: String? = nil, amount: Int = 0) -> ConversionRule? {
        var best: ConversionRule?
        for rule in rules where rule.event == event && rule.minAmount <= amount && (rule.name == nil || rule.name == name) {
            guard let current = best else { best = rule; continue }
            if rank(rule) > rank(current) { best = rule }
        }
        return best
    }

    /// The rule to send for an event, or nil when none applies or it would lower the highest fine value already sent.
    static func next(_ rules: [ConversionRule], event: String, name: String? = nil, amount: Int = 0,
                     highestSent: Int?) -> ConversionRule? {
        guard let rule = best(rules, event: event, name: name, amount: amount), rule.fineValue >= highestSent ?? 0 else { return nil }
        return rule
    }

    private static func rank(_ rule: ConversionRule) -> (Int, Int, Int) {
        (rule.minAmount, rule.name == nil ? 0 : 1, rule.fineValue)
    }
}

struct CachedRules: Codable, Sendable {
    let appId: String
    let fetchedAt: Date
    let rules: [ConversionRule]
}

/// `GET /v1/mobile/config/<appId>`.
struct MobileConfig: Decodable, Sendable {
    let rules: [ConversionRule]

    private enum CodingKeys: String, CodingKey { case conversionRules }
    private struct Entry: Decodable {
        let rule: ConversionRule?
        init(from decoder: any Decoder) throws { rule = try? ConversionRule(from: decoder) }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A rule this SDK version cannot read is skipped; the rest of the mapping still applies.
        rules = (try values.decodeIfPresent([Entry].self, forKey: .conversionRules) ?? []).compactMap(\.rule)
    }
}
