import Foundation

/// Only the echo of this fresh challenge proves that the custom control path
/// survives an SDK link-state transition. Neither a send success nor PCM does.
struct TottiControlProbePolicy {
    private(set) var pending: String?
    private var deadline = 0.0
    mutating func issue(_ nonce:String,at now:TimeInterval) {
        pending=nonce;deadline=now+6
    }
    mutating func acknowledge(_ nonce:String) -> Bool {
        guard let pending, pending == nonce else { return false }
        self.pending=nil;return true
    }
    func expired(_ nonce:String,at now:TimeInterval) -> Bool {
        pending == nonce && now >= deadline
    }
    mutating func cancel(){pending=nil}
}
