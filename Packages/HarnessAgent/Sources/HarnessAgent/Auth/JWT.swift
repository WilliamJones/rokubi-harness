import Foundation

/// Claims we read from the OpenAI id_token / access_token. The signature is not
/// verified — the token came straight from the token endpoint over TLS and is
/// only used to learn which account to address requests to.
public struct IDTokenClaims: Sendable, Equatable {
    public var email: String?
    public var chatgptAccountID: String?
    public var planType: String?
    public var expiresAt: Date?

    /// Parses the payload segment of a JWT. Returns nil if it isn't three base64url parts.
    public static func parse(_ jwt: String) -> IDTokenClaims? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3,
              let data = Data(base64URLEncoded: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var claims = IDTokenClaims()
        let profile = json["https://api.openai.com/profile"] as? [String: Any]
        let auth = json["https://api.openai.com/auth"] as? [String: Any]
        claims.email = (json["email"] as? String) ?? (profile?["email"] as? String)
        claims.chatgptAccountID = auth?["chatgpt_account_id"] as? String
        claims.planType = auth?["chatgpt_plan_type"] as? String
        if let exp = json["exp"] as? TimeInterval { claims.expiresAt = Date(timeIntervalSince1970: exp) }
        return claims
    }
}
