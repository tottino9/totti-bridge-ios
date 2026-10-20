import Foundation
@main struct TottiBargeInChecks {
    static func main() {
        var drain=TottiPlaybackDrain()
        let first=drain.token
        precondition(drain.enqueue(first))
        precondition(drain.enqueue(first))
        precondition(!drain.markEnded(first),"Synthesis completion is not playback completion")
        precondition(!drain.played(first))
        precondition(drain.played(first))
        precondition(!drain.played(first),"No duplicate completion")
        precondition(!drain.markEnded(first))
        let next=drain.reset()
        precondition(!drain.played(first),"Late callback cannot finish next answer")
        precondition(!drain.enqueue(first))
        precondition(drain.enqueue(next))
        precondition(!drain.played(next))
        precondition(drain.markEnded(next),"Playback can drain before synthesis terminal callback")
        let empty=drain.reset()
        precondition(drain.markEnded(empty))
        precondition(!drain.enqueue(empty))
        for _ in 0..<100 {
            let old=drain.reset();precondition(drain.enqueue(old))
            let new=drain.reset();precondition(drain.enqueue(new))
            precondition(!drain.played(old));precondition(!drain.markEnded(old))
            precondition(!drain.markEnded(new));precondition(drain.played(new))
        }
        print("PASS playback drain: actual playback completion, cancellation fences, duplicate callbacks, 100 interrupted turns")
    }
}
