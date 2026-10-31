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
}
