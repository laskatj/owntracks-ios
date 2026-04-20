//
//  WatchOAuthRefresher.swift
//  SauronWatch
//
//  Stub: wire to your token endpoint. See docs/watch/WATCH_AUTH_API.md
//

import Foundation

enum WatchOAuthRefresherError: Error {
    case notImplemented
    case noRefreshToken
    case httpError(Int)
}

/// Placeholder refresh client. Replace `refreshURL` and body with your IdP contract.
final class WatchOAuthRefresher {
    /// Called when ingest returns 401 and `WatchAuthTokens.refreshToken` is set.
    func refreshTokens(current: WatchAuthTokens, refreshURL: URL?, clientId: String?) async throws -> WatchAuthTokens {
        guard let refresh = current.refreshToken, !refresh.isEmpty else {
            throw WatchOAuthRefresherError.noRefreshToken
        }
        // Spike path: no default issuer URL on watch — phone must push token endpoint via WatchConfig in a future revision.
        guard let url = refreshURL else {
            throw WatchOAuthRefresherError.notImplemented
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = "grant_type=refresh_token&refresh_token=\(refresh.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let cid = clientId {
            body += "&client_id=\(cid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        }
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WatchOAuthRefresherError.notImplemented }
        guard (200...299).contains(http.statusCode) else { throw WatchOAuthRefresherError.httpError(http.statusCode) }
        // Expect JSON: access_token, refresh_token?, expires_in
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let access = obj?["access_token"] as? String else {
            throw WatchOAuthRefresherError.notImplemented
        }
        let newRefresh = obj?["refresh_token"] as? String ?? refresh
        let expiresIn = obj?["expires_in"] as? Double
        let expiry = expiresIn.map { Date().timeIntervalSince1970 + $0 }
        return WatchAuthTokens(accessToken: access, refreshToken: newRefresh, accessTokenExpiry: expiry)
    }
}
