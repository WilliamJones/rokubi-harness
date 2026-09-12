import Foundation
import Testing
@testable import HarnessAgent

@Suite struct AuthPrimitivesTests {
    @Test func pkceChallengeIsBase64URLSHA256OfVerifier() {
        let pkce = PKCE()
        #expect(pkce.verifier.count >= 43)
        #expect(!pkce.challenge.contains("="))
        #expect(!pkce.challenge.contains("+"))
        #expect(pkce.challenge.count == 43)
    }

    @Test func jwtClaimsAreRead() {
        let payload: [String: Any] = [
            "email": "dev@example.com",
            "exp": 1_900_000_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct_123",
                "chatgpt_plan_type": "plus",
            ],
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let jwt = "eyJhbGciOiJSUzI1NiJ9." + json.base64URLEncoded() + ".sig"
        let claims = IDTokenClaims.parse(jwt)
        #expect(claims?.email == "dev@example.com")
        #expect(claims?.chatgptAccountID == "acct_123")
        #expect(claims?.planType == "plus")
        #expect(claims?.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(IDTokenClaims.parse("not-a-jwt") == nil)
    }

    @Test func sseParserSplitsEvents() {
        var parser = SSEParser()
        var events = parser.feed("event: response.created\ndata: {\"a\":1}\n\nevent: response.output_text.delta\ndata: {\"delta\":\"hi\"}\n")
        #expect(events.count == 1)
        #expect(events[0].event == "response.created")
        #expect(events[0].data == "{\"a\":1}")
        events = parser.feed("\ndata: [DONE]\n\n")
        #expect(events.count == 2)
        #expect(events[0].event == "response.output_text.delta")
        #expect(events[1].data == "[DONE]")
        #expect(parser.finish() == nil)
    }

    @Test func sseParserJoinsMultiLineDataAndHandlesCRLF() {
        var parser = SSEParser()
        let events = parser.feed("data: line1\r\ndata: line2\r\n\r\n")
        #expect(events == [SSEEvent(event: nil, data: "line1\nline2")])
    }
}
