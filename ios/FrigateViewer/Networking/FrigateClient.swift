import Foundation

enum FrigateError: LocalizedError {
    case unauthorized
    case http(Int, String)
    case invalidResponse
    case loginFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Not signed in, or the session expired."
        case let .http(code, body): return "Server returned \(code). \(body)"
        case .invalidResponse: return "Unexpected response from the server."
        case let .loginFailed(msg): return "Sign-in failed: \(msg)"
        }
    }
}

/// Talks to Frigate's HTTP API through its nginx front end.
///
/// Auth: `POST /api/login` sets a JWT cookie (`frigate_token` by default).
/// We keep that JWT and send it as `Authorization: Bearer …`, which Frigate's
/// auth check accepts on every proxied path (API, /vod, /clips, websockets).
final class FrigateClient: @unchecked Sendable {
    let settings: ServerSettings
    private let session: URLSession
    private let trust: TrustDelegate
    private let lock = NSLock()
    private var _token: String?
    private var _cookieName: String
    private var password: String?

    init(settings: ServerSettings, password: String?) {
        self.settings = settings
        self.password = password
        self._token = Keychain.get("token")
        self._cookieName = Keychain.get("cookieName") ?? "frigate_token"
        self.trust = TrustDelegate(allowSelfSigned: settings.allowSelfSigned, host: settings.baseURL.host)
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
    }

    var token: String? { lock.withLock { _token } }
    var cookieName: String { lock.withLock { _cookieName } }

    // MARK: URLs

    var baseURL: URL { settings.baseURL }

    /// Builds `<base>/<path>` (path without a leading slash).
    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var basePath = comps.percentEncodedPath
        if !basePath.hasSuffix("/") { basePath += "/" }
        comps.percentEncodedPath = basePath + trimmed
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    /// websocket URL for go2rtc's WebRTC signalling, proxied by Frigate.
    func webRTCSocketURL(stream: String) -> URL {
        var comps = URLComponents(url: url("live/webrtc/api/ws", query: [URLQueryItem(name: "src", value: stream)]),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        return comps.url!
    }

    /// HLS playlist of recordings for a camera between two unix timestamps.
    func vodURL(camera: String, start: Double, end: Double) -> URL {
        url("vod/\(camera.pathEscaped)/start/\(Int(start))/end/\(Int(end.rounded(.up)))/index.m3u8")
    }

    /// Thumbnails are stored as `/media/frigate/clips/...` and served at `/clips/...`.
    func mediaURL(forStoredPath path: String) -> URL {
        url(path.replacingOccurrences(of: "/media/frigate/", with: ""))
    }

    var authHeaders: [String: String] {
        guard let token else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }

    var authCookie: HTTPCookie? {
        guard let token, let host = baseURL.host else { return nil }
        return HTTPCookie(properties: [
            .name: cookieName, .value: token, .domain: host, .path: "/",
        ])
    }

    // MARK: Auth

    func login(username: String? = nil, password: String? = nil) async throws {
        let user = username ?? settings.username
        guard let pass = password ?? self.password, !user.isEmpty else { throw FrigateError.unauthorized }
        var req = URLRequest(url: url("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user": user, "password": pass])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FrigateError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw FrigateError.loginFailed(msg ?? "HTTP \(http.statusCode)")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { acc, kv in
            if let k = kv.key as? String, let v = kv.value as? String { acc[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: req.url!)
        // Cookie name is configurable in Frigate; take the one holding a JWT.
        guard let jwt = cookies.first(where: { $0.name == "frigate_token" })
            ?? cookies.first(where: { $0.value.split(separator: ".").count == 3 }) else {
            throw FrigateError.loginFailed("no session cookie in response")
        }
        lock.withLock {
            _token = jwt.value
            _cookieName = jwt.name
            self.password = pass
        }
        Keychain.set(jwt.value, for: "token")
        Keychain.set(jwt.name, for: "cookieName")
        Keychain.set(pass, for: "password")
    }

    /// Makes sure a token exists, signing in if credentials are stored.
    func ensureSession() async throws {
        if settings.usesAuth && token == nil { try await login() }
    }

    // MARK: Requests

    func data(_ path: String, query: [URLQueryItem] = [], retryAuth: Bool = true) async throws -> Data {
        var req = URLRequest(url: url(path, query: query))
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw FrigateError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403, settings.usesAuth {
            if retryAuth, password != nil {
                try await login()
                return try await self.data(path, query: query, retryAuth: false)
            }
            throw FrigateError.unauthorized
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw FrigateError.http(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await self.data(path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw FrigateError.http(200, "Could not read \(path): \(error)")
        }
    }

    // MARK: Endpoints

    func version() async throws -> String {
        String(decoding: try await data("api/version"), as: UTF8.self)
    }

    func cameras() async throws -> [Camera] {
        let config = try await get(FrigateConfig.self, "api/config")
        return config.cameras.values
            .map(Camera.init)
            .filter { $0.enabled }
            .sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }

    func recordings(camera: String, after: Double, before: Double) async throws -> [RecordingSegment] {
        try await get([RecordingSegment].self, "api/\(camera.pathEscaped)/recordings", query: [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "before", value: String(before)),
        ])
    }

    func reviews(cameras: [String]?, severity: ReviewItem.Severity?, after: Double, before: Double, limit: Int = 200) async throws -> [ReviewItem] {
        var q = [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "before", value: String(before)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "cameras", value: cameras?.joined(separator: ",") ?? "all"),
        ]
        if let severity { q.append(URLQueryItem(name: "severity", value: severity.rawValue)) }
        return try await get([ReviewItem].self, "api/review", query: q)
    }

    func latestFrame(camera: String, height: Int) async throws -> Data {
        try await data("api/\(camera.pathEscaped)/latest.jpg", query: [
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "cache", value: String(Int(Date().timeIntervalSince1970))),
        ])
    }

    func image(at url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw FrigateError.invalidResponse
        }
        return data
    }
}

/// Optionally trusts a self-signed certificate for the configured host only.
final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowSelfSigned: Bool
    let host: String?

    init(allowSelfSigned: Bool, host: String?) {
        self.allowSelfSigned = allowSelfSigned
        self.host = host
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if allowSelfSigned,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == host,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

extension String {
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
