import Foundation
#if os(iOS)
import StoreKit
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif
#endif

protocol ConversionUpdating: Sendable {
    /// False where Apple offers no conversion postbacks (tvOS, macOS). Every conversion call is then a no-op.
    var isSupported: Bool { get }
    /// Hands the values to the system and returns the frameworks that accepted them.
    func update(fineValue: Int, coarseValue: ConversionCoarseValue, lockWindow: Bool) async -> [ConversionFramework]
}

/// Apple's conversion APIs. SKAdNetwork and AdAttributionKit keep separate postbacks, and Apple's guidance for apps
/// measured through both is to call both, so each update goes to every framework the running OS has.
struct SystemConversions: ConversionUpdating {
    /// SKAdNetwork mirrors each of its updates into AdAttributionKit with the fine value and lock only. A locking
    /// update therefore goes to AdAttributionKit first, so that postback locks with the coarse value too; any other
    /// update goes to SKAdNetwork first, so the complete AdAttributionKit call comes last.
    static func order(lockWindow: Bool) -> [ConversionFramework] {
        lockWindow ? [.adAttributionKit, .skAdNetwork] : [.skAdNetwork, .adAttributionKit]
    }

    #if os(iOS)
    let isSupported = true

    func update(fineValue: Int, coarseValue: ConversionCoarseValue, lockWindow: Bool) async -> [ConversionFramework] {
        var accepted: [ConversionFramework] = []
        for framework in Self.order(lockWindow: lockWindow) {
            let done = framework == .skAdNetwork
                ? await skAdNetwork(fineValue, coarseValue, lockWindow)
                : await adAttributionKit(fineValue, coarseValue, lockWindow)
            if done { accepted.append(framework) }
        }
        return accepted
    }

    private func skAdNetwork(_ fine: Int, _ coarse: ConversionCoarseValue, _ lock: Bool) async -> Bool {
        do {
            if #available(iOS 16.1, *) {
                let value: SKAdNetwork.CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
                try await SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: value, lockWindow: lock)
            } else if #available(iOS 15.4, *) {
                // SKAdNetwork 3: a fine value only. Coarse values and window locks do not exist before iOS 16.1.
                try await SKAdNetwork.updatePostbackConversionValue(fine)
            } else {
                // iOS 15.0 to 15.3 have only this call, which reports no outcome.
                SKAdNetwork.updateConversionValue(fine)
            }
            return true
        } catch {
            return false
        }
    }

    private func adAttributionKit(_ fine: Int, _ coarse: ConversionCoarseValue, _ lock: Bool) async -> Bool {
        #if canImport(AdAttributionKit)
        guard #available(iOS 17.4, *) else { return false }
        do {
            let value: AdAttributionKit.CoarseConversionValue = coarse == .high ? .high : coarse == .medium ? .medium : .low
            try await AdAttributionKit.Postback.updateConversionValue(fine, coarseConversionValue: value, lockPostback: lock)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
    #else
    let isSupported = false

    func update(fineValue: Int, coarseValue: ConversionCoarseValue, lockWindow: Bool) async -> [ConversionFramework] { [] }
    #endif
}
