import Foundation

/// The network seam. `URLSession` is the production transport; tests substitute a stub.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct SessionTransport: Transport {
    let session: URLSession

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LinkRunwayError.invalidResponse }
        return (data, http.statusCode)
    }
}

extension LinkRunway {
    /// True while consent is on and has not been withdrawn since `started` was read.
    func isCurrent(_ started: Int) -> Bool { consent && started == epoch }

    func post<T: Encodable & Sendable, R: Decodable & Sendable>(_ path: String, _ payload: T) async throws -> R {
        let (data, _) = try await call("POST", path, body: try JSONEncoder().encode(payload))
        return try JSONDecoder().decode(R.self, from: data)
    }

    /// One API call with the SDK's retry policy: three attempts, backing off on 429, 5xx, and network errors.
    func call(_ method: String, _ path: String, id: String? = nil, body: Data? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: route(path, id))
        request.httpMethod = method
        request.setValue(Platform.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let started = epoch
        for attempt in 0..<3 {
            guard isCurrent(started) else { throw LinkRunwayError.consentRequired }
            do {
                let (data, status) = try await env.transport.send(request)
                if (status == 429 || status >= 500) && attempt < 2 {
                    try await env.sleep(0.3 * Double(1 << attempt))
                    continue
                }
                guard (200..<300).contains(status) else {
                    throw LinkRunwayError.server(status, String(data: data, encoding: .utf8) ?? "Request failed")
                }
                return (data, status)
            } catch let error as URLError where attempt < 2 {
                if error.code == .cancelled { throw error }
                try await env.sleep(0.3 * Double(1 << attempt))
            }
        }
        throw LinkRunwayError.invalidResponse
    }

    private func route(_ path: String, _ id: String?) -> URL {
        let url = endpoint.appendingPathComponent("v1/\(path)")
        guard let id, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        // An ID is exactly one path segment: anything outside this set is escaped so it cannot change the route.
        parts.percentEncodedPath += "/" + (id.addingPercentEncoding(withAllowedCharacters: Self.segment) ?? "")
        return parts.url ?? url
    }

    private static let segment = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")
}
