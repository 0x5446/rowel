/// The split that makes streaming affordable.
///
/// `Markdown.settle` divides text at the last block boundary so the prefix can
/// render behind an equality check. That is only sound if the division is
/// invisible: the two halves parsed apart must be the whole parsed together,
/// for every shape of half-arrived text — and the prefix must never rewrite
/// itself mid-stream, or the skip it exists for stops firing.

import XCTest
@testable import Rowel

final class MarkdownSettleTests: XCTestCase {
    /// Shapes chosen for their boundary behaviour: fences that swallow blank
    /// lines, constructs that need adjacency, blanks in every position.
    private let corpus = [
        "",
        "one paragraph, no boundary",
        "two\nlines of one paragraph",
        "first\n\nsecond",
        "first\n\nsecond\n\n",
        "\n\nleading blanks",
        "a\n\n\n\nb",
        "para\n\n- one\n- two\n\n1. first\n2. second",
        "# Title\n\ntext under it\n\n---\n\n> a quote",
        "before\n\n```swift\ncode\n\nstill code after a blank line\n```\n\nafter",
        "before\n\n```\nan unterminated fence\n\nwith a blank inside",
        "tilde\n\n~~~\nfenced\n\n~~~\n\ntail",
        "intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\noutro",
        "text\n\n```\n---\n\n# not a heading, code\n```",
    ]

    func testHalvesParseAsTheWhole() {
        for source in corpus {
            let (settled, live) = Markdown.settle(source)
            XCTAssertEqual(
                Markdown.parse(settled) + Markdown.parse(live),
                Markdown.parse(source),
                "split changed the reading of: \(source.debugDescription)"
            )
        }
    }

    func testSingleBlockStaysWhollyLive() {
        let (settled, live) = Markdown.settle("still being written")
        XCTAssertEqual(settled, "")
        XCTAssertEqual(live, "still being written")
    }

    func testBlankInsideOpenFenceIsNotABoundary() {
        let (settled, _) = Markdown.settle("a\n\n```\nx\n\ny")
        XCTAssertEqual(settled, "a", "an open fence must keep its interior live")
    }

    /// Stream a document in and require the settled prefix to only ever grow.
    /// A prefix that shrank or changed would re-render the whole bubble — the
    /// exact cost this split removes.
    func testSettledPrefixIsStableUnderStreaming() {
        let document = corpus.joined(separator: "\n\n")
        var previous = ""
        var partial = ""
        for character in document {
            partial.append(character)
            let (settled, _) = Markdown.settle(partial)
            XCTAssertTrue(
                settled.hasPrefix(previous),
                "settled text rewrote itself at: \(partial.suffix(30).debugDescription)"
            )
            previous = settled
        }
    }

    // MARK: - The fast path says what the slow one said

    /// The implementation `settle` had before it stopped copying every line,
    /// kept verbatim as the reference the fast one is held to.
    private func referenceSettle(_ source: String) -> (settled: String, live: String) {
        let lines = source.components(separatedBy: "\n")
        var fence: String?
        var lastBlank = -1
        var boundary = -1
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { fence = nil }
            } else if trimmed.isEmpty {
                lastBlank = index
            } else {
                if lastBlank >= 0 { boundary = lastBlank }
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    fence = String(trimmed.prefix(3))
                }
            }
        }
        guard boundary > 0 else { return ("", source) }
        return (lines[..<boundary].joined(separator: "\n"), lines[(boundary + 1)...].joined(separator: "\n"))
    }

    /// Every prefix of every corpus entry — the shapes text passes through as
    /// it streams — plus the awkward characters: CRLF, which `components`
    /// splits and `Character` does not, and whitespace that is not ASCII.
    func testTheFastSplitMatchesTheReferenceOnEveryPrefix() {
        let extra = [
            "crlf\r\n\r\nnext\r\n",
            "wide\u{3000}space\n\u{3000}\nafter",
            "\u{3000}```\nfenced by a wide space\n\nstill fenced\n",
            "emoji 👩🏽‍💻 line\n\n```\n👍\n\n```\n\ndone",
        ]
        for source in corpus + extra {
            var prefix = ""
            for character in source {
                prefix.append(character)
                let fast = Markdown.settle(prefix)
                let reference = referenceSettle(prefix)
                XCTAssertEqual(fast.settled, reference.settled, "settled half differs for \(prefix.debugDescription)")
                XCTAssertEqual(fast.live, reference.live, "live half differs for \(prefix.debugDescription)")
            }
        }
    }

    /// A code block drawn in slices must draw every character, once.
    func testCodeSlicesAreLossless() {
        for lines in [0, 1, 39, 40, 41, 80, 81, 1_000] {
            let text = (0..<lines).map { "line \($0)" }.joined(separator: "\n")
            let slices = CodeBlock.slices(text)
            XCTAssertEqual(slices.joined(separator: "\n"), text, "\(lines) lines")
            XCTAssertTrue(slices.dropLast().allSatisfy { $0.components(separatedBy: "\n").count == CodeBlock.sliceLines })
        }
        XCTAssertEqual(CodeBlock.slices("ends with a newline\n").joined(separator: "\n"), "ends with a newline\n")
    }
}
