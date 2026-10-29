#if TOTTI_EXPERIMENTAL_DUPLEX
import Foundation

/// Cancelling invalidates scheduled audio callbacks before the next utterance.
struct TottiPlaybackDrain {
    private(set) var token = UUID()
    private var pending = 0
    private var ended = false
    private var delivered = false
    mutating func reset() -> UUID {
        token = UUID(); pending = 0; ended = false; delivered = false
        return token
    }
    mutating func enqueue(_ id:UUID) -> Bool {
        guard token == id, !ended, !delivered else { return false }
        pending += 1; return true
    }
    mutating func markEnded(_ id:UUID) -> Bool {
        guard token == id, !delivered else { return false }
        ended = true; return takeCompletion()
    }
    mutating func played(_ id:UUID) -> Bool {
        guard token == id, pending > 0, !delivered else { return false }
        pending -= 1; return takeCompletion()
    }
    private mutating func takeCompletion() -> Bool {
        guard ended, pending == 0, !delivered else { return false }
        delivered = true; return true
    }
}
#endif
