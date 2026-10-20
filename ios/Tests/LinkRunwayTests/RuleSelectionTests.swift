import Foundation
import Testing
@testable import LinkRunway

private func rule(_ event: String, _ fine: Int, name: String? = nil, min: Int = 0,
                  coarse: ConversionCoarseValue = .low, lock: Bool = false) -> ConversionRule {
    ConversionRule(event: event, name: name, minAmount: min, fineValue: fine, coarseValue: coarse, lockWindow: lock)
}

private let mapping: [ConversionRule] = [
    rule("INSTALL", 0),
    rule("SIGNUP", 5),
    rule("CUSTOM", 2),
    rule("CUSTOM", 9, name: "level_10", coarse: .medium),
    rule("CUSTOM", 7, name: "tutorial"),
    rule("PURCHASE", 20, coarse: .medium),
    rule("PURCHASE", 40, min: 1_000, coarse: .high),
    rule("PURCHASE", 60, min: 10_000, coarse: .high, lock: true),
    rule("PURCHASE", 30, name: "starter_pack", min: 1_000, coarse: .medium),
    rule("SUBSCRIPTION", 50, min: 500, coarse: .high),
]

struct SelectionCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let event: String
    let name: String?
    let amount: Int
    /// The fine value of the rule that should be chosen, or nil when no rule applies.
    let expected: Int?

    init(_ description: String, _ event: String, _ name: String? = nil, amount: Int = 0, expect expected: Int?) {
        self.testDescription = description
        self.event = event
        self.name = name
        self.amount = amount
        self.expected = expected
    }
}

@Suite struct RuleSelectionTests {
    @Test(arguments: [
        SelectionCase("an event type without a rule maps to nothing", "OPEN", expect: nil),
        SelectionCase("an install maps to its rule, fine value zero included", "INSTALL", expect: 0),
        SelectionCase("event types are matched exactly", "install", expect: nil),
        SelectionCase("an unnamed custom event uses the generic rule", "CUSTOM", expect: 2),
        SelectionCase("an unlisted custom name falls back to the generic rule", "CUSTOM", "other", expect: 2),
        SelectionCase("a named rule beats the generic one", "CUSTOM", "level_10", expect: 9),
        SelectionCase("names are case-sensitive", "CUSTOM", "Level_10", expect: 2),
        SelectionCase("a name on another event type does not match", "SIGNUP", "level_10", expect: 5),
        SelectionCase("the lowest purchase tier", "PURCHASE", amount: 999, expect: 20),
        SelectionCase("a threshold is inclusive", "PURCHASE", amount: 1_000, expect: 40),
        SelectionCase("the highest threshold not above the amount wins", "PURCHASE", amount: 9_999, expect: 40),
        SelectionCase("the top tier", "PURCHASE", amount: 250_000, expect: 60),
        SelectionCase("a named rule wins at an equal threshold", "PURCHASE", "starter_pack", amount: 1_500, expect: 30),
        SelectionCase("a higher threshold beats a named rule", "PURCHASE", "starter_pack", amount: 10_000, expect: 60),
        SelectionCase("a named rule does not apply below its threshold", "PURCHASE", "starter_pack", amount: 500, expect: 20),
        SelectionCase("an amount below every threshold maps to nothing", "SUBSCRIPTION", amount: 499, expect: nil),
        SelectionCase("a negative amount maps to nothing", "PURCHASE", amount: -1, expect: nil),
    ])
    func choosesTheBestMatchingRule(_ example: SelectionCase) {
        let chosen = ConversionRules.best(mapping, event: example.event, name: example.name, amount: example.amount)
        #expect(chosen?.fineValue == example.expected)
    }

    @Test func breaksTiesByFineValueThenByOrder() {
        let higher = [rule("SIGNUP", 3), rule("SIGNUP", 8, coarse: .high), rule("SIGNUP", 6)]
        #expect(ConversionRules.best(higher, event: "SIGNUP") == higher[1])
        let identical = [rule("SIGNUP", 4, coarse: .low), rule("SIGNUP", 4, coarse: .high)]
        #expect(ConversionRules.best(identical, event: "SIGNUP")?.coarseValue == .low)
        #expect(ConversionRules.best([], event: "SIGNUP") == nil)
    }

    @Test func returnsTheWholeRuleIncludingTheLock() {
        let chosen = ConversionRules.best(mapping, event: "PURCHASE", amount: 10_000)
        #expect(chosen == rule("PURCHASE", 60, min: 10_000, coarse: .high, lock: true))
        #expect(ConversionRules.best(mapping, event: "PURCHASE", amount: 5_000)?.lockWindow == false)
    }

    @Test func neverChoosesAValueBelowTheHighestSent() {
        #expect(ConversionRules.next(mapping, event: "INSTALL", highestSent: nil)?.fineValue == 0)
        #expect(ConversionRules.next(mapping, event: "SIGNUP", highestSent: nil)?.fineValue == 5)
        #expect(ConversionRules.next(mapping, event: "SIGNUP", highestSent: 4)?.fineValue == 5)
        // The same value may be sent again: it changes nothing in the first window and refreshes later ones.
        #expect(ConversionRules.next(mapping, event: "SIGNUP", highestSent: 5)?.fineValue == 5)
        #expect(ConversionRules.next(mapping, event: "SIGNUP", highestSent: 6) == nil)
        #expect(ConversionRules.next(mapping, event: "INSTALL", highestSent: 5) == nil)
        #expect(ConversionRules.next(mapping, event: "PURCHASE", amount: 1_000, highestSent: 20)?.fineValue == 40)
        #expect(ConversionRules.next(mapping, event: "OPEN", highestSent: nil) == nil)
    }

    @Test func aSequenceOfEventsOnlyEverRaisesTheValue() {
        let events: [(String, String?, Int)] = [
            ("INSTALL", nil, 0), ("SIGNUP", nil, 0), ("CUSTOM", "tutorial", 0), ("PURCHASE", nil, 1_200),
            ("OPEN", nil, 0), ("SIGNUP", nil, 0), ("CUSTOM", "level_10", 0), ("PURCHASE", nil, 300),
            ("PURCHASE", nil, 25_000), ("SUBSCRIPTION", nil, 900), ("PURCHASE", nil, 25_000),
        ]
        var highest: Int?
        var sent: [Int] = []
        for (event, name, amount) in events {
            guard let next = ConversionRules.next(mapping, event: event, name: name, amount: amount, highestSent: highest) else { continue }
            sent.append(next.fineValue)
            highest = next.fineValue
        }
        #expect(sent == [0, 5, 7, 40, 60, 60])
        #expect(sent == sent.sorted())
    }

    @Test func decodesTheServerMappingAndSkipsRulesItCannotRead() throws {
        let json = """
        {"id":"app_1","conversionRules":[
          {"event":"SIGNUP","minAmount":0,"fineValue":5,"coarseValue":"low","lockWindow":false},
          {"event":"PURCHASE","name":"","minAmount":1000,"fineValue":40,"coarseValue":"high","lockWindow":true},
          {"event":"CUSTOM","name":"level_10","fineValue":9,"coarseValue":"medium"},
          {"event":"PURCHASE","minAmount":0,"fineValue":64,"coarseValue":"high","lockWindow":false},
          {"event":"PURCHASE","minAmount":0,"fineValue":12,"coarseValue":"extreme","lockWindow":false},
          {"event":"TRIAL","minAmount":0,"fineValue":3,"coarseValue":"low","lockWindow":false}
        ]}
        """
        let rules = try JSONDecoder().decode(MobileConfig.self, from: Data(json.utf8)).rules
        #expect(rules == [
            rule("SIGNUP", 5),
            // An empty name is no name.
            rule("PURCHASE", 40, min: 1_000, coarse: .high, lock: true),
            // Omitted fields take the server's defaults.
            rule("CUSTOM", 9, name: "level_10", coarse: .medium),
            // A fine value above 63 and an unknown coarse value are skipped; a new event type is kept.
            rule("TRIAL", 3),
        ])
        #expect(try JSONDecoder().decode(MobileConfig.self, from: Data(#"{"id":"app_1"}"#.utf8)).rules.isEmpty)
    }

    @Test func cachedRulesSurviveARoundTrip() throws {
        let cached = CachedRules(appId: "app_1", fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), rules: mapping)
        let decoded = try JSONDecoder().decode(CachedRules.self, from: JSONEncoder().encode(cached))
        #expect(decoded.rules == mapping)
        #expect(decoded.appId == "app_1")
        #expect(decoded.fetchedAt == cached.fetchedAt)
    }
}
