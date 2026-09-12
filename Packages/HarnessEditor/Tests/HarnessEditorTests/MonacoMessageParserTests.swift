import Testing
@testable import HarnessEditor

@Suite struct MonacoMessageParserTests {
    @Test func parsesContentChanged() {
        let (event, response) = MonacoMessageParser.parse(
            ["type": "contentChanged", "id": "doc1", "version": 7, "text": "hello"] as [String: Any]
        )
        #expect(response == nil)
        guard case let .contentChanged(id, version, text)? = event else {
            Issue.record("expected contentChanged"); return
        }
        #expect(id == "doc1")
        #expect(version == 7)
        #expect(text == "hello")
    }

    @Test func parsesDiffHunkResponse() {
        let body: [String: Any] = [
            "type": "response", "requestId": "r1",
            "hunks": [["index": 0, "originalStart": 3, "originalEnd": 4, "modifiedStart": 3, "modifiedEnd": 5]],
        ]
        let (event, response) = MonacoMessageParser.parse(body)
        #expect(event == nil)
        #expect(response?.id == "r1")
        #expect(response?.1.hunks.first?.modifiedEnd == 5)
    }

    @Test func ignoresUnknownTypes() {
        let (event, response) = MonacoMessageParser.parse(["type": "nope"] as [String: Any])
        #expect(event == nil)
        #expect(response == nil)
    }
}
