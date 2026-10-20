import Foundation

extension LinkRunway {
    /// Loads the app's conversion mapping and turns on automatic conversion updates for this instance.
    /// `appId` is the app's ID in the LinkRunway console. The mapping is cached on device and refreshed at most daily.
    /// Returns the active rules; an empty list without consent and on platforms without conversion postbacks.
    @discardableResult
    public func configureConversions(appId: String) async throws -> [ConversionRule] {
        conversionAppId = appId
        guard consent, env.conversions.isSupported else { return [] }
        if let fresh = freshRules(appId) { return fresh }
        do {
            return try await refreshRules(appId)
        } catch {
            // A mapping from an earlier day still applies while the server cannot be reached.
            guard let stale = cachedRules(appId) else { throw error }
            return stale.rules
        }
    }

    /// Updates Apple's conversion value for something the app knows and LinkRunway ingests elsewhere, such as a
    /// purchase your backend reports with a server key. `amount` is in minor units. Nothing is sent to LinkRunway.
    /// Returns once the update has been handed to the system, or nil when there was nothing to hand over.
    @discardableResult
    public func recordConversion(event: String, name: String? = nil, amount: Int = 0) async -> ConversionUpdate? {
        await queueConversion(event: event.uppercased(), name: name, amount: amount, since: epoch)?.value ?? nil
    }

    /// Queues a conversion update. Updates reach Apple one at a time, in the order they were requested, so a lower
    /// value can never arrive after a higher one. `track` does not wait for the queue: the event is already
    /// recorded, and Apple's conversion APIs can take seconds to answer. An update still waiting when consent is
    /// withdrawn is dropped, even if consent is given again before its turn.
    @discardableResult
    func queueConversion(event: String, name: String?, amount: Int, since started: Int) -> Task<ConversionUpdate?, Never>? {
        guard isCurrent(started), env.conversions.isSupported, conversionAppId != nil else { return nil }
        let previous = conversionWork
        let task = Task { () -> ConversionUpdate? in
            _ = await previous?.value
            return await self.applyConversion(event: event, name: name, amount: amount, since: started)
        }
        conversionWork = task
        return task
    }

    private func applyConversion(event: String, name: String?, amount: Int, since started: Int) async -> ConversionUpdate? {
        guard isCurrent(started), env.conversions.isSupported, let appId = conversionAppId else { return nil }
        let active = await activeRules(appId)
        guard isCurrent(started),
              let rule = ConversionRules.next(active, event: event, name: name, amount: amount,
                                              highestSent: store.integer(.highestFine)) else { return nil }
        // The high-water mark is what was handed over, whether or not the system accepted it.
        store.set(rule.fineValue, .highestFine)
        let frameworks = await env.conversions.update(fineValue: rule.fineValue, coarseValue: rule.coarseValue,
                                                      lockWindow: rule.lockWindow)
        return ConversionUpdate(fineValue: rule.fineValue, coarseValue: rule.coarseValue, lockWindow: rule.lockWindow,
                                frameworks: frameworks)
    }

    private func cachedRules(_ appId: String) -> CachedRules? {
        if rules == nil { rules = store.value(.rules) }
        return rules?.appId == appId ? rules : nil
    }

    private func freshRules(_ appId: String) -> [ConversionRule]? {
        guard let cached = cachedRules(appId) else { return nil }
        // A fetch time in the future (the clock moved back) counts as stale.
        return (0..<86_400).contains(env.now().timeIntervalSince(cached.fetchedAt)) ? cached.rules : nil
    }

    private func activeRules(_ appId: String) async -> [ConversionRule] {
        if let fresh = freshRules(appId) { return fresh }
        if let wait = rulesRetryAfter, env.now() < wait { return cachedRules(appId)?.rules ?? [] }
        return (try? await refreshRules(appId)) ?? cachedRules(appId)?.rules ?? []
    }

    private func refreshRules(_ appId: String) async throws -> [ConversionRule] {
        let started = epoch
        // Set before the request so that a failure is not followed by another fetch on the very next event.
        rulesRetryAfter = env.now().addingTimeInterval(300)
        let (data, _) = try await call("GET", "mobile/config", id: appId)
        let fetched = try JSONDecoder().decode(MobileConfig.self, from: data).rules
        guard isCurrent(started) else { return [] }
        let cached = CachedRules(appId: appId, fetchedAt: env.now(), rules: fetched)
        rules = cached
        store.save(cached, .rules)
        return fetched
    }
}
