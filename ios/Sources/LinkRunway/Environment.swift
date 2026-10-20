import Foundation

/// Everything the SDK reaches outside itself, so tests run without a network, a clock, or Apple services.
struct Environment: Sendable {
    var transport: any Transport
    /// The store for a suite name. Apps always get the `UserDefaults` suite.
    var storage: @Sendable (String) -> any KeyValueStore = { UserDefaults(suiteName: $0)! }
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var conversions: any ConversionUpdating = SystemConversions()
    var adServicesToken: (@Sendable () async throws -> String)? = AdServicesSource.system
    var appAttest: (any AppAttesting)? = AppAttestSource.system
    var osVersion: String? = Platform.osVersion
    var language: String? = Platform.language(Locale.preferredLanguages.first)
}

enum Platform {
    #if os(tvOS)
    static let name = "tvos", agent = "tvOS"
    #else
    // The API recognizes iOS and tvOS clients. macOS builds (unit tests, Mac Catalyst) report as iOS.
    static let name = "ios", agent = "iOS"
    #endif
    /// `/v1/resolve` accepts only ios, android, and web.
    static let resolveName = "ios"
    static var userAgent: String { "LinkRunwaySDK/\(LinkRunway.sdkVersion) \(agent)" }

    /// Major.minor of iOS or tvOS. A Mac reports its own version, which would be wrong under the `ios` platform.
    static var osVersion: String? {
        #if (os(iOS) && !targetEnvironment(macCatalyst)) || os(tvOS)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
        #else
        return nil
        #endif
    }

    /// The preferred language when it has the shape the API validates; an unusual tag is left out rather than failing the request.
    static func language(_ tag: String?) -> String? {
        guard let tag, tag.count <= 35,
              tag.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else { return nil }
        return tag
    }
}

enum Timestamp {
    static func string(_ date: Date) -> String { formatter(fractional: true).string(from: date) }

    static func date(_ text: String) -> Date? {
        formatter(fractional: true).date(from: text) ?? formatter(fractional: false).date(from: text)
    }

    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }
}
