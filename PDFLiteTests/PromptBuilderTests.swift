import XCTest

final class PromptBuilderTests: XCTestCase {
    func testSystemPromptHasNoBacktickPairSplitAcrossLines() throws {
        let messages = PromptBuilder.messages(sourceText: "Hello.")
        let system = try XCTUnwrap(messages.first?["content"])

        // A `\n` escape inside the Swift literal once put real line breaks between backticks
        // in the paragraph rule, leaving the model an unreadable, half-empty code span.
        for (index, line) in system.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            XCTAssertEqual(line.filter { $0 == "`" }.count % 2, 0,
                           "Line \(index) has an unbalanced backtick: \(line)")
        }
        XCTAssertFalse(system.contains("\n\n"), "The system prompt must not contain blank lines")
        XCTAssertTrue(system.contains("空行"), "The paragraph rule should describe blank lines in words")
    }

    func testMessagesCarrySourceTextAndTargetLanguage() {
        let messages = PromptBuilder.messages(sourceText: "Some source.", targetLanguage: "日本語")
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertTrue(messages[0]["content"]?.contains("日本語") == true)
        XCTAssertTrue(messages[1]["content"]?.hasSuffix("Some source.") == true)
    }
}
