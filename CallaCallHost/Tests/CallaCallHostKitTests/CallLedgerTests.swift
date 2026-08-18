import IntelligenceCore
import XCTest
@testable import CallaCallHostKit

/// The ledger is the copilot's memory of a call, and its whole reason to exist is
/// that the account **grows** while what gets sent stays bounded. These pin both
/// halves of that: nothing said is lost when a chunk closes, and nothing unbounded
/// is carried into a question.
final class CallLedgerTests: XCTestCase {
    private func statement(_ text: String, seq: Int, speaker: Speaker = .remote) -> Statement {
        Statement(
            fromSeq: seq, toSeq: seq, speaker: speaker, text: text, span: 2, truncated: false)
    }

    private func statements(_ count: Int, from: Int) -> [Statement] {
        (0 ..< count).map { statement("turn \(from + $0)", seq: from + $0) }
    }

    /// Closing a chunk is what replaces transcript with summary: the raw statements
    /// leave and the points take their place.
    func testAClosedChunkDropsItsRawStatements() {
        var ledger = CallLedger()
        ledger.append(statements(3, from: 0))
        XCTAssertEqual(ledger.tail.count, 3)

        let material = ledger.takeTail()
        XCTAssertTrue(ledger.tail.isEmpty)
        ledger.applyChunk(points: ["forty services on k8s"], openQuestions: nil, throughSeq: material.last!.toSeq)

        XCTAssertEqual(ledger.chunks.count, 1)
        XCTAssertEqual(ledger.pointCount, 1)
        XCTAssertTrue(ledger.tail.isEmpty)
        XCTAssertFalse(ledger.questionContext([statement("when can you start?", seq: 9)]).contains("turn 0"))
    }

    /// A failed request must not cost the call its transcript: the statements go
    /// back and the next chunk carries them.
    func testAFailedChunkPutsItsStatementsBack() {
        var ledger = CallLedger()
        ledger.append(statements(3, from: 0))
        let material = ledger.takeTail()
        ledger.append(statements(1, from: 3))

        ledger.restore(material)

        XCTAssertEqual(ledger.tail.count, 4)
        XCTAssertEqual(ledger.tail.map(\.toSeq), [0, 1, 2, 3])
    }

    /// The point of the second lane: points accumulate rather than being rewritten.
    func testPointsAccumulateAcrossChunks() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["budget capped at 30k a month"], openQuestions: nil, throughSeq: 3)
        ledger.applyChunk(points: ["ingestion peaks at 12k events a second"], openQuestions: nil, throughSeq: 7)

        XCTAssertEqual(ledger.chunks.count, 2)
        let account = ledger.accountLines
        XCTAssertTrue(account.contains("budget capped at 30k a month"))
        XCTAssertTrue(account.contains("ingestion peaks at 12k events a second"))
    }

    /// Models send bullets however plainly they are asked not to, and the panel
    /// would show them.
    func testBulletsAndBlanksAreStripped() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["- sharded by tenant", "  ", "• redis assumed"], openQuestions: nil, throughSeq: 1)

        XCTAssertEqual(ledger.chunks.first?.points, ["sharded by tenant", "redis assumed"])
    }

    /// An empty reply must not append an empty chunk — that would make the fold
    /// threshold arrive without any points behind it.
    func testAnEmptyChunkIsNotRecorded() {
        var ledger = CallLedger()
        ledger.applyChunk(points: [], openQuestions: ["when can they start"], throughSeq: 4)

        XCTAssertTrue(ledger.chunks.isEmpty)
        XCTAssertEqual(ledger.openQuestions, ["when can they start"])
    }

    /// The fold takes the oldest points and leaves the recent ones, which is what
    /// keeps the account growing without the prompt growing with it.
    func testFoldingConsumesTheOldestChunksAndKeepsTheRecentOnes() {
        var ledger = CallLedger()
        for index in 0 ..< 5 {
            ledger.applyChunk(
                points: ["point \(index)a", "point \(index)b", "point \(index)c"],
                openQuestions: nil,
                throughSeq: index * 4)
        }
        XCTAssertTrue(ledger.needsFold)

        let folding = ledger.foldable()
        XCTAssertEqual(folding.count, 3)
        ledger.applyFold(standing: "platform interview; 12k events/sec, 30k budget", over: folding.count)

        XCTAssertEqual(ledger.chunks.count, 2)
        XCTAssertEqual(ledger.standing, "platform interview; 12k events/sec, 30k budget")
        XCTAssertFalse(ledger.needsFold)
        // The folded facts are still in the account, in the standing line.
        XCTAssertTrue(ledger.accountLines.first?.contains("30k budget") == true)
        XCTAssertTrue(ledger.accountLines.contains("point 4c"))
    }

    /// A fold that comes back empty must change nothing, or the earlier call would
    /// be dropped in exchange for nothing.
    func testAnEmptyFoldKeepsTheChunks() {
        var ledger = CallLedger()
        for index in 0 ..< 5 {
            ledger.applyChunk(points: ["p\(index)a", "p\(index)b", "p\(index)c"], openQuestions: nil, throughSeq: index)
        }
        ledger.applyFold(standing: "   ", over: 3)

        XCTAssertEqual(ledger.chunks.count, 5)
        XCTAssertTrue(ledger.standing.isEmpty)
    }

    /// A single fat chunk at the head must still fold, or `needsFold` stays true
    /// forever and the exec lane runs every cycle for nothing.
    func testOneOversizedChunkStillFolds() {
        var ledger = CallLedger()
        ledger.applyChunk(
            points: (0 ..< 13).map { "point \($0)" }, openQuestions: nil, throughSeq: 4)

        XCTAssertTrue(ledger.needsFold)
        XCTAssertEqual(ledger.foldable().count, 1)
    }

    /// The question carries the account as fact and the last few turns verbatim —
    /// the mix is the point, because a question is usually about the verbatim part.
    func testQuestionContextIsAccountThenVerbatimThenTheQuestion() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["budget capped at 30k"], openQuestions: nil, throughSeq: 2)
        ledger.applyFold(standing: "platform interview with Mark", over: 0) // no-op: nothing to fold over
        ledger.append([statement("we already cache reads in Redis", seq: 6)])

        let context = ledger.questionContext([statement("so how would you scale it?", seq: 7)])
        let account = try! XCTUnwrap(context.range(of: "So far:"))
        let verbatim = try! XCTUnwrap(context.range(of: "Just said:"))
        XCTAssertTrue(account.lowerBound < verbatim.lowerBound)
        XCTAssertTrue(context.contains("budget capped at 30k"))
        XCTAssertTrue(context.contains("Them: we already cache reads in Redis"))
        XCTAssertTrue(context.hasSuffix("Them: so how would you scale it?"))
    }

    /// The whole reason for the three layers: an hour of call must not turn into an
    /// hour of prompt. With chunks closing every four statements and folding above
    /// twelve points, what a question carries has a ceiling.
    func testQuestionContextStaysBoundedOverALongCall() {
        var ledger = CallLedger()
        var seq = 0
        for chunk in 0 ..< 50 {
            ledger.append(statements(4, from: seq))
            seq += 4
            let material = ledger.takeTail()
            ledger.applyChunk(
                points: ["chunk \(chunk) established something durable about the system"],
                openQuestions: nil,
                throughSeq: material.last!.toSeq)
            if ledger.needsFold {
                let folding = ledger.foldable()
                ledger.applyFold(
                    standing: "the earlier part of the call, folded into two lines of durable fact",
                    over: folding.count)
            }
        }
        ledger.append(statements(3, from: seq))

        let context = ledger.questionContext([statement("and when could you start?", seq: seq + 3)])
        // 200 statements in; a naive transcript would be tens of thousands of
        // characters by now.
        XCTAssertLessThan(context.count, 2000)
        XCTAssertLessThanOrEqual(ledger.pointCount, CallLedger.foldAboveLines)
    }

    /// The panel is a log: standing fact on top, then every point in the order it
    /// was recorded, newest at the bottom. The panel follows its own bottom, so
    /// nothing above the newest line ever moves.
    func testPanelSummaryAppendsNewPointsAtTheBottom() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["older point"], openQuestions: nil, throughSeq: 1)
        ledger.applyChunk(points: ["newer point"], openQuestions: nil, throughSeq: 2)
        ledger.applyFold(standing: "standing fact", over: 0)

        XCTAssertEqual(ledger.panelSummary(), "standing fact\n\nolder point\nnewer point")

        ledger.applyChunk(points: ["newest point"], openQuestions: nil, throughSeq: 3)
        // The lines already on screen are untouched; the new one is added below.
        XCTAssertEqual(
            ledger.panelSummary(), "standing fact\n\nolder point\nnewer point\nnewest point")
    }

    /// What the chunk lane is shown as already recorded, so it stops re-saying the
    /// same fact in new words.
    func testLastPointsReturnsTheNewestRecordedLinesInOrder() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["a", "b"], openQuestions: nil, throughSeq: 1)
        ledger.applyChunk(points: ["c", "d"], openQuestions: nil, throughSeq: 2)

        XCTAssertEqual(ledger.lastPoints(3), ["b", "c", "d"])
        XCTAssertEqual(ledger.lastPoints(99), ["a", "b", "c", "d"])
    }

    /// The closing pass gets everything, including whatever never made it into a
    /// chunk before the call ended.
    func testClosingBriefCarriesTheTailAndTheLeftovers() {
        var ledger = CallLedger()
        ledger.applyChunk(points: ["agreed on a pilot"], openQuestions: ["start date"], throughSeq: 3)
        ledger.append([statement("send the contract Friday", seq: 8, speaker: .local)])

        let closing = ledger.closingBrief(with: [statement("we will review Monday", seq: 9)])
        XCTAssertTrue(closing.contains("agreed on a pilot"))
        XCTAssertTrue(closing.contains("Me: send the contract Friday"))
        XCTAssertTrue(closing.contains("Them: we will review Monday"))
        XCTAssertTrue(closing.contains("start date"))
    }
}
