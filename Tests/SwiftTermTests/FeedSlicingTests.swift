import Foundation
import Testing
@testable import SwiftTerm

final class FeedSlicingTests {
    private static let options = TerminalOptions(cols: 40, rows: 8, scrollback: 200)

    private final class Recorder: TerminalDelegate, @unchecked Sendable {
        var sent: [UInt8] = []
        var titles: [String] = []
        var iconTitles: [String] = []
        var clipboard: [[UInt8]] = []
        var programStatus: [[TerminalProgramStatus]] = []
        var synchronizedOutput: [Bool] = []
        var bells = 0

        func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
        func setTerminalTitle(source: Terminal, title: String) { titles.append(title) }
        func setTerminalIconTitle(source: Terminal, title: String) { iconTitles.append(title) }
        func clipboardCopy(source: Terminal, content: TerminalData) { clipboard.append(Array(content)) }
        func programStatusChanged(source: Terminal, records: [TerminalProgramStatus]) {
            programStatus.append(records)
        }
        func synchronizedOutputChanged(source: Terminal, active: Bool) { synchronizedOutput.append(active) }
        func bell(source: Terminal) { bells += 1 }
        func isProcessTrusted(source: Terminal) -> Bool { true }

        var fingerprint: String {
            "sent \(sent) titles \(titles) icons \(iconTitles) clipboard \(clipboard) " +
                "status \(programStatus) sync \(synchronizedOutput) bells \(bells)"
        }
    }

    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    private static let samplePieces: [[UInt8]] = [
        "plain ascii text that runs long enough to wrap the forty columns ",
        "\u{1b}[1;31mred\u{1b}[0m ", "\u{1b}[38;5;208m256\u{1b}[39m ",
        "\u{1b}[38;2;10;200;30;48;2;1;2;3mtrue\u{1b}[m ", "\u{1b}[4:3mcurly\u{1b}[24m ",
        "漢字かな ", "e\u{301}\u{302} ", "👩‍👩‍👧 ", "🇯🇵 ", "\t|\r\n",
        "\u{1b}[3;5H", "\u{1b}[2K", "\u{1b}[J", "\u{1b}[2;6r\u{1b}[5S\u{1b}[r",
        "\u{1b}]0;title ✓\u{07}", "\u{1b}]1;icon\u{1b}\\", "\u{1b}]2;window\u{07}",
        "\u{1b}]8;id=7;https://example.com/a\u{1b}\\link\u{1b}]8;;\u{1b}\\ ",
        "\u{1b}]52;c;aGVsbG8gY2xpcGJvYXJk\u{07}", "\u{1b}]7501;state=working:app=claude-code\u{07}",
        "\u{1b}]10;?\u{07}", "\u{1b}P$qm\u{1b}\\", "\u{1b}P+q544e\u{1b}\\",
        "\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\",
        "\u{1b}[6n", "\u{1b}[5n", "\u{1b}[c", "\u{1b}[>c", "\u{1b}[?2026$p",
        "\u{1b}[?1h", "\u{1b}[?1l", "\u{1b}[?2004h", "\u{1b}[?1000h", "\u{1b}[?1000l", "\u{1b}[4h", "\u{1b}[4l",
        "\u{1b}[?2026h", "\u{1b}[?2026l", "\u{1b}7\u{1b}[10C*\u{1b}8", "\n\n\n", "\u{07}",
        "\u{1b}[?1049h alt \u{1b}[?1049l", "\u{1b}[3@", "\u{1b}[2P",
    ].map { Array($0.utf8) } + [
        [0x9b, 0x33, 0x32, 0x6d, 0x43, 0x31, 0x9b, 0x6d],
        [0x9d, 0x30, 0x3b, 0x63, 0x31, 0x9c],
        [0x84, 0x85, 0x41],
    ]

    private static func mixedSample(seed: UInt64, count: Int) -> [UInt8] {
        let pieces = samplePieces
        var state = seed
        var result: [UInt8] = []
        while result.count < count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result += pieces[Int(state >> 33) % pieces.count]
        }
        return result
    }

    private struct Fingerprint: Equatable {
        var state: [String] = []
        var rows: [String] = []
        var attributes: [Attribute] = []
        var payloads: [String] = []
    }

    private static func fingerprint(_ terminal: Terminal, _ recorder: Recorder) -> Fingerprint {
        terminal.terminalLock.withLock { fingerprintLocked(terminal, recorder) }
    }

    private static func fingerprintLocked(_ terminal: Terminal, _ recorder: Recorder) -> Fingerprint {
        let buffer = terminal.buffer
        var result = Fingerprint()
        result.state = [
            "cursor \(buffer.x),\(buffer.y) base \(buffer.yBase) alt \(terminal.isCurrentBufferAlternate)",
            "modes \(terminal.inputStateSnapshotLocked()) hidden \(terminal.cursorHidden) " +
                "origin \(terminal.originMode) insert \(terminal.insertMode) " +
                "wrap \(terminal.wraparound) sync \(terminal.synchronizedOutputActive) " +
                "title \(terminal.terminalTitle)",
            recorder.fingerprint,
        ]
        for index in 0..<buffer.lines.count {
            let line = buffer.lines[index]
            var row = line.isWrapped ? "w " : "  "
            for column in 0..<terminal.cols {
                let cell = line[column]
                row.append(cell.getCharacter())
                row += "/\(line.getWidth(index: column));"
                result.attributes.append(cell.attribute)
                if let payload = cell.getPayload() {
                    result.payloads.append("\(index),\(column) \(payload)")
                }
            }
            result.rows.append(row)
        }
        return result
    }

    private static func parsed(_ chunks: [ArraySlice<UInt8>]) -> Fingerprint {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder, options: options)
        terminal.terminalLock.withLock {
            for chunk in chunks {
                terminal.feed(buffer: chunk)
            }
        }
        return fingerprint(terminal, recorder)
    }

    @Test func splittingABatchAtAnyByteGivesTheSameState() {
        let bytes = Array(Self.samplePieces.joined())
        let whole = Self.parsed([bytes[...]])
        #expect(!whole.state[2].contains("sent [] "), "the sample draws replies")
        #expect(!whole.state[2].contains("clipboard [] "), "the sample sets the clipboard")
        for split in 0...bytes.count {
            let result = Self.parsed([bytes[..<split], bytes[split...]])
            #expect(result == whole, "split at \(split) of \(bytes.count)")
            if result != whole { break }
        }
    }

    @Test func splittingABatchIntoManyPiecesGivesTheSameState() {
        for seed in UInt64(2)...6 {
            let bytes = Self.mixedSample(seed: seed, count: 20_000)
            let whole = Self.parsed([bytes[...]])
            var state = seed
            var chunks: [ArraySlice<UInt8>] = []
            var start = 0
            while start < bytes.count {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                let end = min(bytes.count, start + 1 + Int(state >> 33) % 300)
                chunks.append(bytes[start..<end])
                start = end
            }
            #expect(Self.parsed(chunks) == whole, "seed \(seed)")
        }
    }


    @Test func pieceEndsNeverSplitAUTF8Scalar() {
        let slicer = TerminalFeedSlicer()
        let size = slicer.pieceBytes
        for lead in 0..<4 {
            for scalar in ["é", "漢", "👩", "\u{85}"] {
                let bytes = Array(repeating: UInt8(ascii: "a"), count: size - lead)
                    + Array(scalar.utf8) + Array(repeating: UInt8(ascii: "b"), count: 10)
                let end = bytes.withUnsafeBufferPointer { buffer in
                    slicer.pieceEnd(in: buffer.span, from: 0)
                }
                let scalarStart = size - lead
                let scalarEnd = scalarStart + scalar.utf8.count
                #expect(end == size || end == scalarStart || end == scalarEnd)
                #expect(end <= size)
                #expect(bytes[end] & 0xC0 != 0x80, "lead \(lead) \(scalar)")
            }
        }
    }

    @Test func pieceEndsTakeTheRestWhenItFitsAndTolerateBadUTF8() {
        let slicer = TerminalFeedSlicer()
        let short = Array(repeating: UInt8(0x41), count: slicer.pieceBytes)
        short.withUnsafeBufferPointer { buffer in
            #expect(slicer.pieceEnd(in: buffer.span, from: 0) == slicer.pieceBytes)
            #expect(slicer.pieceEnd(in: buffer.span, from: 7) == slicer.pieceBytes)
        }
        let continuations = Array(repeating: UInt8(0x80), count: slicer.pieceBytes * 2)
        continuations.withUnsafeBufferPointer { buffer in
            #expect(slicer.pieceEnd(in: buffer.span, from: 0) == slicer.pieceBytes)
            #expect(slicer.pieceEnd(in: buffer.span, from: 5) == slicer.pieceBytes + 5)
        }
    }

    @Test func theFirstPieceOfAHoldFillsTheMinimumHold() {
        let slicer = TerminalFeedSlicer()
        let bytes = Array(repeating: UInt8(0x41), count: slicer.pieceBytes * 8)
        let scale = Int(TerminalFeedSlicer.minimumHoldNs / TerminalFeedSlicer.pieceNs)
        bytes.withUnsafeBufferPointer { buffer in
            #expect(slicer.pieceEnd(in: buffer.span, from: 0, budgetNs: TerminalFeedSlicer.minimumHoldNs)
                    == slicer.pieceBytes * scale)
            #expect(slicer.pieceEnd(in: buffer.span, from: 0) == slicer.pieceBytes)
        }
    }

    @Test func pieceSizeFollowsTheMeasuredRate() {
        var slicer = TerminalFeedSlicer()
        let start = slicer.pieceBytes
        slicer.record(bytes: start, nanoseconds: TerminalFeedSlicer.pieceNs * 8)
        #expect(slicer.pieceBytes == start / 8)

        slicer.record(bytes: 10, nanoseconds: TerminalFeedSlicer.pieceNs * 1_000)
        #expect(slicer.pieceBytes == start / 8, "a short piece is ignored")

        slicer.record(bytes: slicer.pieceBytes, nanoseconds: 1)
        #expect(slicer.pieceBytes == start / 8 * TerminalFeedSlicer.growthLimit)

        for _ in 0..<10 {
            slicer.record(bytes: slicer.pieceBytes, nanoseconds: 1)
        }
        #expect(slicer.pieceBytes == TerminalFeedSlicer.maximumPiece)

        slicer.record(bytes: slicer.pieceBytes, nanoseconds: UInt64.max / 2)
        #expect(slicer.pieceBytes == TerminalFeedSlicer.minimumPiece)
    }

    @Test func hasWaitersReportsAThreadBlockedOnTheLock() {
        let lock = TerminalLock()
        #expect(!lock.hasWaiters)
        lock.lock()
        #expect(!lock.hasWaiters)
        let acquired = DispatchSemaphore(value: 0)
        let box = Unchecked(value: lock)
        DispatchQueue.global().async {
            box.value.withLock {}
            acquired.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while !lock.hasWaiters && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(lock.hasWaiters)
        lock.unlock()
        #expect(acquired.wait(timeout: .now() + 5) == .success)
        #expect(!lock.hasWaiters)
    }

#if os(macOS) || os(Linux)
    private static let threadSanitized = dlsym(dlopen(nil, RTLD_NOW), "__tsan_init") != nil

    @Test(.disabled(if: threadSanitized, "an exit test's child process runs without TSan's interceptors"))
    func aFeedUnderTheTerminalLockTrapsWhileAnotherFeedWaitsForIt() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
            let terminal = Terminal(delegate: FeedSlicingTests.Recorder(), options: FeedSlicingTests.options)
            let selection = terminal.terminalLock.withLock { SelectionService(terminal: terminal) }
            terminal.terminalLock.lock()
            let box = FeedSlicingTests.Unchecked(value: (terminal, selection))
            DispatchQueue.global().async {
                box.value.0.feedPreservingSelection(Array("y".utf8)[...], selection: box.value.1)
            }
            while !terminal.terminalLock.hasWaiters {
                usleep(1_000)
            }
            terminal.feedPreservingSelection(Array("x".utf8)[...], selection: selection)
            exit(0)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("the feed gate or terminalLock"), "\(stderr)")
    }

    @Test(.disabled(if: threadSanitized, "an exit test's child process runs without TSan's interceptors"))
    func aFeedFromInsideAFeedTrapsNamingTheFeedGate() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { exit(0) }
            let terminal = Terminal(delegate: FeedSlicingTests.Recorder(), options: FeedSlicingTests.options)
            _ = Array("x".utf8).withUnsafeBufferPointer { buffer in
                terminal.feedInHolds(buffer.span, beginHold: {}, endHold: {}, afterHold: {
                    terminal.feedInHolds(buffer.span, beginHold: {}, endHold: {}, afterHold: {})
                })
            }
            exit(0)
        }
        let stderr = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(stderr.contains("the feed gate or terminalLock"), "\(stderr)")
    }
#endif


    private struct Contention {
        var acquisitions = 0
        var worstWaitNs: UInt64 = 0
    }

    private static func contended(
        _ lock: TerminalLock,
        feed: @escaping @Sendable () -> Void,
        whileHeld: () -> Void = {}
    ) -> Contention {
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            feed()
            done.signal()
        }
        started.wait()
        var contention = Contention()
        while done.wait(timeout: .now()) == .timedOut {
            let begin = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                contention.worstWaitNs = max(contention.worstWaitNs, DispatchTime.now().uptimeNanoseconds - begin)
                contention.acquisitions += 1
                whileHeld()
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return contention
    }

    private static let rowCounterCount = 60_000

    private static func rowCounterWrites(count: Int) -> [UInt8] {
        var result: [UInt8] = []
        for index in 0..<count {
            result += Array("\u{1b}[8;1H\(index)".utf8)
        }
        return result
    }

    private static func row(_ terminal: Terminal, _ row: Int) -> String {
        terminal.buffer.lines[terminal.buffer.yBase + row].translateToString(trimRight: true)
    }

    private static func selectionOverwrite(_ changesSelection: Bool) -> [UInt8] {
        changesSelection ? Array("\u{1b}[1;1HNEEDLE".utf8) : []
    }

    private static func isClearedMidFeed(_ terminal: Terminal, _ selection: SelectionService) -> Bool {
        !selection.active && row(terminal, 7) != "\(rowCounterCount - 1)"
    }

    @Test func theStandaloneFeedHandsTheLockToAWaiterAndChecksTheSelection() {
        for changesSelection in [false, true] {
            let terminal = Terminal(delegate: Recorder(), options: Self.options)
            let selection = terminal.terminalLock.withLock {
                terminal.feed(text: "needle")
                let selection = SelectionService(terminal: terminal)
                selection.setSelection(start: Position(col: 0, row: 0), end: Position(col: 6, row: 0))
                return selection
            }
            let bytes = Self.selectionOverwrite(changesSelection) + Self.rowCounterWrites(count: Self.rowCounterCount)
            let box = Unchecked(value: (terminal, selection))
            var clearedMidFeed = false
            let contention = Self.contended(terminal.terminalLock, feed: {
                box.value.0.feedPreservingSelection(bytes[...], selection: box.value.1)
            }) {
                clearedMidFeed = clearedMidFeed || Self.isClearedMidFeed(terminal, selection)
            }
            #expect(contention.acquisitions >= 10, "the waiter got in \(contention.acquisitions) times")
            #expect(clearedMidFeed == changesSelection)
            #expect(terminal.terminalLock.withLock { selection.active } == !changesSelection)
        }
    }

    @Test func anotherStandaloneFeedNeverLandsInsideAFeed() {
        let terminal = Terminal(delegate: Recorder(), options: TerminalOptions(cols: 80, rows: 10, scrollback: 50_000))
        let selection = terminal.terminalLock.withLock { SelectionService(terminal: terminal) }
        let box = Unchecked(value: (terminal, selection))
        Self.expectFeedsStayWhole(terminal) { bytes in
            box.value.0.feedPreservingSelection(bytes[...], selection: box.value.1)
        }
    }

    private static func expectFeedsStayWhole(_ terminal: Terminal, feed: @escaping @Sendable ([UInt8]) -> Void) {
        let big = Array(String(repeating: String(repeating: "a", count: 70) + "\r\n", count: 5_000).utf8)
        let started = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            started.signal()
            feed(big)
            done.signal()
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.005)
        feed(Array("\u{1b}[31mB\r\n".utf8))
        #expect(done.wait(timeout: .now() + 60) == .success)

        let rows = terminal.terminalLock.withLock {
            (0..<terminal.buffer.lines.count).map {
                terminal.buffer.lines[$0].translateToString(trimRight: true)
            }
        }
        let b = rows.firstIndex { $0.contains("B") }
        #expect(b.map { rows[$0] } == "B", "B landed inside a line of the other feed")
        if let b {
            let before = rows[..<b].contains { $0.hasPrefix("a") }
            let after = rows[(b + 1)...].contains { $0.hasPrefix("a") }
            #expect(!(before && after), "B landed inside the other feed")
        }
    }

}
