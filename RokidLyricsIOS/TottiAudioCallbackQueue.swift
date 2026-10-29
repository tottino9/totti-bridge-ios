#if TOTTI_EXPERIMENTAL_DUPLEX
import Foundation

/// Serialize callback payloads before creating actor tasks. Actor tasks alone are not FIFO.
final class TottiAudioCallbackQueue<Element>: @unchecked Sendable {
    enum Offered { case schedule, queued, overflow }
    private let lock=NSLock()
    private var entries:[(Element,Int)]=[]
    private var bytes=0
    private var scheduled=false
    func offer(_ value:Element, bytes cost:Int) -> Offered {
        lock.lock();defer{lock.unlock()}
        guard cost >= 0, cost <= 4_194_304-bytes, entries.count<256 else {return .overflow}
        entries.append((value,cost));bytes += cost
        if scheduled {return .queued}
        scheduled=true;return .schedule
    }
    func take() -> Element? {
        lock.lock();defer{lock.unlock()}
        guard !entries.isEmpty else {scheduled=false;return nil}
        let (value,cost)=entries.removeFirst();bytes -= cost;return value
    }
    func clear() {lock.lock();entries.removeAll();bytes=0;lock.unlock()}
}
#endif
