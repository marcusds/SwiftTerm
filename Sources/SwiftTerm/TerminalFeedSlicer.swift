//
//  TerminalFeedSlicer.swift
//  SwiftTerm
//

#if !SWIFTTERM_EMBEDDED && !os(WASI)

/// Sizes feed pieces by the measured parse rate; a piece never ends inside a UTF-8 scalar.
struct TerminalFeedSlicer {
    static let pieceNs: UInt64 = 1_000_000
    static let minimumHoldNs: UInt64 = 2_000_000
    static let minimumPiece = 256
#if os(iOS) || os(Windows) || os(Android)
    static let maximumPiece = 65_536
#else
    static let maximumPiece = TerminalIOPipeline.bufferCapacity
#endif
    static let growthLimit = 4

    private(set) var pieceBytes = 4_096

    func pieceEnd(in bytes: Span<UInt8>, from start: Int,
                  budgetNs: UInt64 = TerminalFeedSlicer.pieceNs) -> Int {
        precondition(start >= 0 && start <= bytes.count)
        let size = max(1, Int(UInt64(pieceBytes) * budgetNs / Self.pieceNs))
        guard bytes.count - start > size else { return bytes.count }
        let end = start + size
        var boundary = end
        let floor = max(start + 1, end - 3)
        while boundary > floor && Self.isContinuation(bytes[boundary]) {
            boundary -= 1
        }
        return Self.isContinuation(bytes[boundary]) ? end : boundary
    }

    mutating func record(bytes: Int, nanoseconds: UInt64) {
        guard bytes > 0, bytes >= pieceBytes / 2 else { return }
        let fit = UInt64(bytes) * Self.pieceNs / max(nanoseconds, 1)
        let limit = min(Self.maximumPiece, pieceBytes * Self.growthLimit)
        pieceBytes = max(Self.minimumPiece, Int(min(fit, UInt64(limit))))
    }

    @inline(__always)
    private static func isContinuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }
}

final class TerminalFeedState {
    let gate = TerminalLock(profiled: false)
    var slicer = TerminalFeedSlicer()
}

extension Terminal {
    /// `beginHold`, `endHold` and `afterHold` must not feed this terminal.
    @discardableResult
    func feedInHolds<HoldState, HoldResult>(
        _ bytes: Span<UInt8>,
        beginHold: () -> HoldState,
        endHold: (HoldState) -> HoldResult,
        afterHold: (HoldResult) -> Void
    ) -> Int {
        let feedState = feedState
        precondition(!terminalLock.isLockedByCurrentThread && !feedState.gate.isLockedByCurrentThread,
                     "A feed cannot start while this thread holds the feed gate or terminalLock, as in a delegate callback or another feed")
        feedState.gate.lock()
        defer { feedState.gate.unlock() }
        var start = 0
        var holds = 0
        repeat {
            let result = terminalLock.withLock {
                let state = beginHold()
                let holdStart = TerminalEventTime.now().uptimeNanoseconds
                var pieceStart = holdStart
                var budget = TerminalFeedSlicer.minimumHoldNs
                parsingBatch {
                    repeat {
                        let end = feedState.slicer.pieceEnd(in: bytes, from: start, budgetNs: budget)
                        let parse = Profiling.begin(.ioParse, "bytes=%d", end - start)
                        feedBorrowed(bytes.extracting(start..<end))
                        parse.end()
                        let finished = TerminalEventTime.now().uptimeNanoseconds
                        feedState.slicer.record(bytes: end - start, nanoseconds: finished &- pieceStart)
                        pieceStart = finished
                        start = end
                        budget = TerminalFeedSlicer.pieceNs
                    } while start < bytes.count
                        && !(pieceStart &- holdStart >= TerminalFeedSlicer.minimumHoldNs
                             && terminalLock.hasWaiters)
                }
                return endHold(state)
            }
            holds += 1
            afterHold(result)
        } while start < bytes.count
        return holds
    }
}

#endif
