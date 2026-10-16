import Foundation

/// Evidence for the actual HTTP transaction, not an inference from Wi-Fi settings.
final class TottiNetworkMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = "unknown"
    var transport: String {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }
        let evidence: String
        if transactions.isEmpty { evidence = "unknown" }
        else if transactions.allSatisfy({ $0.isCellular }) { evidence = "cellular" }
        else if transactions.allSatisfy({ !$0.isCellular }) { evidence = "nonCellular" }
        else { evidence = "mixed" }
        lock.lock(); value = evidence; lock.unlock()
        print("[TottiNetwork] transport=\(evidence) durationMs=\(Int(metrics.taskInterval.duration * 1000))")
    }
}
