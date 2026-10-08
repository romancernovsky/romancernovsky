import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import Security

/// Official "Sign in with Google" for the YouTube Data API (OAuth 2.0 with PKCE).
///
/// The sign-in page is Google's own, shown in a secure system browser sheet – the app never sees
/// the password. Afterwards the app keeps only a *refresh token* in the iPhone Keychain and asks
/// for read-only access to YouTube ("youtube.readonly").
///
/// Needs an OAuth client ID of type "iOS" from Google Cloud Console (see README).
@Observable
@MainActor
final class GoogleAuth {

    static let shared = GoogleAuth()

    /// Paste your client ID here to build it into the app, or enter it in Settings at runtime.
    /// Looks like "1234567890-abcdefg.apps.googleusercontent.com".
    nonisolated static let builtInClientID = ""

    enum AuthError: LocalizedError {
        case notConfigured
        case notSignedIn
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Enter your Google OAuth client ID in Settings first."
            case .notSignedIn: return "Please sign in with your YouTube (Google) account."
            case .badResponse(let detail): return "Google sign-in failed: \(detail)"
            }
        }
    }

    private let scope = "https://www.googleapis.com/auth/youtube.readonly"
    private let clientIDKey = "googleOAuthClientID"
    private let keychainAccount = "youtube-refresh-token"

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: clientIDKey) }
    }
    private(set) var isSignedIn = false
    private(set) var accountName: String?
    private(set) var accountImageURL: URL?

    @ObservationIgnored private var accessToken: String?
    @ObservationIgnored private var accessTokenExpiry = Date.distantPast

    var isConfigured: Bool { clientIDPrefix != nil }

    private init() {
        clientID = UserDefaults.standard.string(forKey: clientIDKey) ?? Self.builtInClientID
        isSignedIn = Keychain.read(account: keychainAccount) != nil
        if isSignedIn {
            Task { await loadAccountInfo() }
        }
    }

    // MARK: - Sign in / out

    func signIn(using session: WebAuthenticationSession) async throws {
        guard let prefix = clientIDPrefix else { throw AuthError.notConfigured }
        let cleanID = clientID.trimmingCharacters(in: .whitespaces)

        // Google's rule for iOS clients: the redirect uses the client ID turned around.
        let scheme = "com.googleusercontent.apps.\(prefix)"
        let redirectURI = "\(scheme):/oauthredirect"

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafeString(length: 24)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: cleanID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account"),
        ]

        let callback = try await session.authenticate(using: components.url!, callbackURLScheme: scheme)

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw AuthError.badResponse(error)
        }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.badResponse("unexpected answer from Google")
        }

        let tokens = try await tokenRequest([
            "client_id": cleanID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let refresh = tokens.refreshToken else { throw AuthError.badResponse("no refresh token") }
        Keychain.save(refresh, account: keychainAccount)
        accessToken = tokens.accessToken
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60))
        isSignedIn = true
        await loadAccountInfo()
    }

    func signOut() {
        if let token = Keychain.read(account: keychainAccount) {
            // Tell Google to cancel the permission too (best effort).
            var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncode(["token": token])
            URLSession.shared.dataTask(with: request).resume()
        }
        Keychain.delete(account: keychainAccount)
        accessToken = nil
        accessTokenExpiry = .distantPast
        isSignedIn = false
        accountName = nil
        accountImageURL = nil
    }

    /// A valid access token, refreshed automatically when it has expired (they last 1 hour).
    func validAccessToken() async throws -> String {
        if let accessToken, Date() < accessTokenExpiry { return accessToken }
        guard let refresh = Keychain.read(account: keychainAccount) else { throw AuthError.notSignedIn }
        guard isConfigured else { throw AuthError.notConfigured }
        do {
            let tokens = try await tokenRequest([
                "client_id": clientID.trimmingCharacters(in: .whitespaces),
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ])
            accessToken = tokens.accessToken
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60))
            return tokens.accessToken
        } catch AuthError.badResponse(let detail) where detail.contains("invalid_grant") {
            // Permission was revoked or expired – the user needs to sign in again.
            signOut()
            throw AuthError.notSignedIn
        }
    }

    private func loadAccountInfo() async {
        guard let channel = try? await YouTubeAPI().myChannel() else { return }
        accountName = channel.title
        accountImageURL = channel.thumbnailURL
    }

    // MARK: - Token endpoint

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AuthError.badResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    /// "123-abc.apps.googleusercontent.com" → "123-abc"
    private var clientIDPrefix: String? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        let suffix = ".apps.googleusercontent.com"
        guard id.hasSuffix(suffix), id.count > suffix.count else { return nil }
        return String(id.dropLast(suffix.count))
    }

    private nonisolated static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }

    private nonisolated static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(Data(bytes).base64URLEncoded.prefix(length))
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal wrapper around the iPhone Keychain (encrypted storage for secrets).
enum Keychain {
    private static let service = "YTDownloader.GoogleAuth"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
