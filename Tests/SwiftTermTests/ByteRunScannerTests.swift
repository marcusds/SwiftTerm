import Testing
@testable import SwiftTerm

final class ByteRunScannerTests {
    @Test func scannersMatchScalarSearchesForAllShortLengthsAndStarts() {
        for length in 0...65 {
            var storage = Array(repeating: UInt8(0x41), count: length + 11)
            let lowerBound = 5
            let upperBound = lowerBound + length

            if length > 2 {
                storage[lowerBound + length / 3] = 0x1f
                storage[lowerBound + (length * 2) / 3] = 0x80
            }
            let bytes = storage[lowerBound..<upperBound]

            for start in lowerBound...upperBound {
                #expect(ByteRunScanner.firstC0Byte(in: bytes, from: start) ==
                        scalarFirstC0Byte(in: bytes, from: start))
                #expect(ByteRunScanner.firstNonASCIIByte(in: bytes, from: start) ==
                        scalarFirstNonASCIIByte(in: bytes, from: start))
            }
        }
    }

    @Test func scannersFindMatchesInEveryVectorLane() {
        let lowerBound = 3
        for matchOffset in 0..<64 {
            var storage = Array(repeating: UInt8(0x41), count: 70)
            storage[lowerBound + matchOffset] = 0x1f
            let bytes = storage[lowerBound..<(lowerBound + 64)]
            #expect(ByteRunScanner.firstC0Byte(in: bytes, from: bytes.startIndex) ==
                    bytes.startIndex + matchOffset)

            storage[lowerBound + matchOffset] = 0x80
            let nonASCIIBytes = storage[lowerBound..<(lowerBound + 64)]
            #expect(ByteRunScanner.firstNonASCIIByte(
                in: nonASCIIBytes,
                from: nonASCIIBytes.startIndex) == nonASCIIBytes.startIndex + matchOffset)

        }
    }

    @Test func scannersMatchScalarSearchesForRandomInput() {
        var generator = DeterministicByteGenerator(state: 0x5357_4946_5454_4552)

        for iteration in 0..<1_000 {
            let prefixCount = iteration % 8
            let length = (iteration * 73) % 258
            var storage = Array(repeating: UInt8(0), count: prefixCount + length + 3)
            for index in storage.indices {
                storage[index] = generator.next()
            }

            let bytes = storage[prefixCount..<(prefixCount + length)]
            let start = bytes.startIndex + (length == 0 ? 0 : iteration % (length + 1))
            #expect(ByteRunScanner.firstC0Byte(in: bytes, from: start) ==
                    scalarFirstC0Byte(in: bytes, from: start))
            #expect(ByteRunScanner.firstNonASCIIByte(in: bytes, from: start) ==
                    scalarFirstNonASCIIByte(in: bytes, from: start))
        }
    }

    // The parser feeds the `Span` overloads directly, so they need their own
    // coverage: on Swift 6.3 the `ArraySlice` overloads take a different path.
    @Test func spanScannersMatchScalarSearchesForAllShortLengthsAndStarts() {
        for length in 0...65 {
            var storage = Array(repeating: UInt8(0x41), count: length + 11)
            let lowerBound = 5
            let upperBound = lowerBound + length

            if length > 2 {
                storage[lowerBound + length / 3] = 0x1f
                storage[lowerBound + (length * 2) / 3] = 0x80
                storage[lowerBound + length / 2] = 0x3b
            }
            let bytes = storage[lowerBound..<upperBound]

            for start in 0...length {
                #expect(ByteRunScanner.firstC0Byte(in: bytes.span, from: start) ==
                        scalarFirstC0Byte(in: bytes, from: lowerBound + start) - lowerBound)
                #expect(ByteRunScanner.firstNonASCIIByte(in: bytes.span, from: start) ==
                        scalarFirstNonASCIIByte(in: bytes, from: lowerBound + start) - lowerBound)
                #expect(ByteRunScanner.firstC0OrByte(0x3b, in: bytes.span, from: start) ==
                        scalarFirstC0OrByte(0x3b, in: bytes, from: lowerBound + start) - lowerBound)
            }
        }
    }

    @Test func spanScannersFindMatchesInEveryVectorLane() {
        let lowerBound = 3
        for matchOffset in 0..<64 {
            var storage = Array(repeating: UInt8(0x41), count: 70)
            storage[lowerBound + matchOffset] = 0x1f
            #expect(ByteRunScanner.firstC0Byte(
                in: storage[lowerBound..<(lowerBound + 64)].span, from: 0) == matchOffset)

            storage[lowerBound + matchOffset] = 0x80
            #expect(ByteRunScanner.firstNonASCIIByte(
                in: storage[lowerBound..<(lowerBound + 64)].span, from: 0) == matchOffset)

            storage[lowerBound + matchOffset] = 0x3b
            #expect(ByteRunScanner.firstC0OrByte(
                0x3b, in: storage[lowerBound..<(lowerBound + 64)].span, from: 0) == matchOffset)
        }
    }

    @Test func spanScannersMatchScalarSearchesForRandomInput() {
        var generator = DeterministicByteGenerator(state: 0x5350_414e_5343_414e)

        for iteration in 0..<1_000 {
            let prefixCount = iteration % 8
            let length = (iteration * 73) % 258
            var storage = Array(repeating: UInt8(0), count: prefixCount + length + 3)
            for index in storage.indices {
                storage[index] = generator.next()
            }

            let bytes = storage[prefixCount..<(prefixCount + length)]
            let start = length == 0 ? 0 : iteration % (length + 1)
            #expect(ByteRunScanner.firstC0Byte(in: bytes.span, from: start) ==
                    scalarFirstC0Byte(in: bytes, from: prefixCount + start) - prefixCount)
            #expect(ByteRunScanner.firstNonASCIIByte(in: bytes.span, from: start) ==
                    scalarFirstNonASCIIByte(in: bytes, from: prefixCount + start) - prefixCount)
            #expect(ByteRunScanner.firstC0OrByte(0x07, in: bytes.span, from: start) ==
                    scalarFirstC0OrByte(0x07, in: bytes, from: prefixCount + start) - prefixCount)
        }
    }

    @Test func wordAndVectorScansAgreeWithScalarSearches() {
        var generator = DeterministicByteGenerator(state: 0x574f_5244_5343_414e)
        let targets: [UInt8] = [0x00, 0x07, 0x1b, 0x3b, 0x7f, 0x80, 0x9c, 0xff]

        for iteration in 0..<2_000 {
            let length = (iteration * 37) % 200
            var storage = (0..<length).map { _ in 0x20 + generator.next() % 0x5f }
            for _ in 0..<(iteration % 3) where length > 0 {
                storage[Int(generator.next()) % length] = generator.next()
            }
            let bytes = storage[...]
            let start = length == 0 ? 0 : Int(generator.next()) % (length + 1)
            let target = targets[iteration % targets.count]
            let span = bytes.span

            let c0 = scalarFirstC0Byte(in: bytes, from: start)
            #expect(finish(ByteRunScanner.wordScanC0(in: span, from: start), bytes) { $0 < 0x20 } == c0)
            #expect(finish(ByteRunScanner.vectorScanC0(in: span, from: start), bytes) { $0 < 0x20 } == c0)

            let nonASCII = scalarFirstNonASCIIByte(in: bytes, from: start)
            #expect(finish(ByteRunScanner.wordScanNonASCII(in: span, from: start), bytes) { $0 >= 0x80 } == nonASCII)
            #expect(finish(ByteRunScanner.vectorScanNonASCII(in: span, from: start), bytes) { $0 >= 0x80 } == nonASCII)

            let either = scalarFirstC0OrByte(target, in: bytes, from: start)
            let matches: (UInt8) -> Bool = { $0 < 0x20 || $0 == target }
            #expect(finish(ByteRunScanner.wordScanC0OrByte(target, in: span, from: start), bytes, matches) == either)
            #expect(finish(ByteRunScanner.vectorScanC0OrByte(target, in: span, from: start), bytes, matches) == either)
        }
    }

    @Test func wordAndVectorScansReturnTheStartForEmptyAndShortSpans() {
        for length in 0..<16 {
            let storage = Array(repeating: UInt8(0x41), count: length)
            let slice = storage[...]
            let span = slice.span
            for start in 0...length {
                #expect(ByteRunScanner.vectorScanC0(in: span, from: start) == start)
                #expect(ByteRunScanner.vectorScanNonASCII(in: span, from: start) == start)
                #expect(ByteRunScanner.vectorScanC0OrByte(0x3b, in: span, from: start) == start)
                let wordEnd = start + (length - start) / 8 * 8
                #expect(ByteRunScanner.wordScanC0(in: span, from: start) == wordEnd)
                #expect(ByteRunScanner.wordScanNonASCII(in: span, from: start) == wordEnd)
                #expect(ByteRunScanner.wordScanC0OrByte(0x3b, in: span, from: start) == wordEnd)
            }
        }
    }

    @Test func wordScansStopAtTheWordHoldingEveryByteValue() {
        for value in 0...255 {
            let byte = UInt8(value)
            for offset in 0..<32 {
                var storage = Array(repeating: UInt8(0x41), count: 32)
                storage[offset] = byte
                let slice = storage[...]
                let span = slice.span
                let word = offset / 8 * 8
                #expect(ByteRunScanner.wordScanC0(in: span, from: 0) == (byte < 0x20 ? word : 32))
                #expect(ByteRunScanner.wordScanNonASCII(in: span, from: 0) == (byte >= 0x80 ? word : 32))
                #expect(ByteRunScanner.wordScanC0OrByte(0x9c, in: span, from: 0) ==
                        (byte < 0x20 || byte == 0x9c ? word : 32))
            }
        }
    }

#if DEBUG && !os(WASI)
    @Test func parserGivesTheSameScreenWithWordAndVectorScans() {
        var generator = DeterministicByteGenerator(state: 0x5041_5253_4552_5321)
        let pieces = [
            "\u{1b}[1;38;5;33m", "\u{1b}[0m", "\u{1b}[48;2;1;2;3m", "\r\n", "\t", "é漢字",
            "\u{1b}]0;" + String(repeating: "title ", count: 12) + "\u{07}",
            "\u{1b}]8;;https://example.com/" + String(repeating: "path/", count: 10) + "\u{1b}\\",
            "link\u{1b}]8;;\u{1b}\\", "\u{1b}[5;10H", "\u{1b}[K",
        ].map { Array($0.utf8) }
        var input: [UInt8] = []
        while input.count < 40_000 {
            let choice = Int(generator.next()) % (pieces.count + 3)
            if choice < pieces.count {
                input += pieces[choice]
            } else {
                let length = 1 + Int(generator.next()) % 150
                input += (0..<length).map { _ in 0x20 + generator.next() % 0x5f }
            }
        }
        #expect(screen(after: input, scans: .vector) == screen(after: input, scans: .word))
    }

    private func screen(after input: [UInt8], scans: ByteRunScanner.ScanPath) -> [String] {
        let recorder = TitleRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(cols: 60, rows: 10, scrollback: 400))
        ByteRunScanner.$debugScanPath.withValue(scans) {
            terminal.feed(byteArray: input)
        }
        let buffer = terminal.buffer
        var rows = ["title \(recorder.title) cursor \(buffer.x),\(buffer.y)"]
        for index in 0..<buffer.lines.count {
            let line = buffer.lines[index]
            rows.append((0..<terminal.cols).map { column in
                let cell = line[column]
                return "\(cell.getCharacter())/\(cell.attribute)/\(cell.hasPayload)"
            }.joined(separator: ";"))
        }
        return rows
    }

    private final class TitleRecorder: TerminalDelegate {
        var title = ""
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: Terminal, title: String) {
            self.title = title
        }
    }
#endif

    private func finish(_ index: Int, _ bytes: ArraySlice<UInt8>, _ matches: (UInt8) -> Bool) -> Int {
        var index = index
        while index < bytes.count && !matches(bytes[index]) {
            index += 1
        }
        return index
    }

    private func scalarFirstC0OrByte(_ value: UInt8, in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] < 0x20 || bytes[index] == value {
            return index
        }
        return bytes.endIndex
    }

    private func scalarFirstC0Byte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] < 0x20 {
            return index
        }
        return bytes.endIndex
    }

    private func scalarFirstNonASCIIByte(in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        for index in start..<bytes.endIndex where bytes[index] >= 0x80 {
            return index
        }
        return bytes.endIndex
    }

}

private struct DeterministicByteGenerator {
    var state: UInt64

    mutating func next() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}
