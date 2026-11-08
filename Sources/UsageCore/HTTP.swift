import Foundation

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data
}

enum HTTP {
    static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }

    static func request(
        _ url: URL,
        method: String,
        headers: [String: String],
        body: Data? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
