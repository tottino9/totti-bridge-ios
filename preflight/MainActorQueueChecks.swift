import Foundation
import Dispatch

@MainActor
final class QueueProbe {
    nonisolated let queue = TottiAudioCallbackQueue<Int>()
    var received: [Int] = []
    nonisolated func send(_ value: Int) {
        switch queue.offer(value, bytes: 2) {
        case .schedule:
            Task { @MainActor [weak self] in self?.drain() }
        case .queued: break
        case .overflow: preconditionFailure("unexpected overflow")
        }
    }
    func drain() {
        while let value = queue.take() { received.append(value) }
    }
}

@main struct MainActorQueueChecks {
    @MainActor static func waitFor(_ test: () -> Bool) async throws {
        let end = Date().addingTimeInterval(2)
        while !test() {
            precondition(Date() < end, "MainActor callback delivery timed out")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @MainActor static func main() async throws {
        let fifo = QueueProbe()
        await Task.detached { for i in 0..<128 { fifo.send(i) } }.value
        try await waitFor { fifo.received.count == 128 }
        precondition(fifo.received == Array(0..<128))
        print("PASS real MainActor: serial producer FIFO and scheduled consumer")

        let concurrent = QueueProbe()
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 128) { concurrent.send($0) }
        }.value
        try await waitFor { concurrent.received.count == 128 }
        precondition(Set(concurrent.received) == Set(0..<128))
        print("PASS real MainActor: concurrent producers deliver exactly once; inter-producer order unspecified")

        let cleared = QueueProbe()
        cleared.send(1)
        cleared.queue.clear()
        cleared.send(2)
        try await waitFor { cleared.received.count == 1 }
        precondition(cleared.received == [2])
        cleared.send(3)
        try await waitFor { cleared.received.count == 2 }
        precondition(cleared.received == [2,3])
        print("PASS real MainActor: pending-consumer clear/new callback and empty-queue rearm")

        let bounded = TottiAudioCallbackQueue<Int>()
        for i in 0..<256 { _ = bounded.offer(i, bytes: 1) }
        guard case .overflow = bounded.offer(256, bytes: 1) else { preconditionFailure() }
        var received: [Int] = []
        while let value = bounded.take() { received.append(value) }
        precondition(received == Array(0..<256))
        print("PASS actual queue: count bound preserves existing values on overflow")

        guard case .schedule = bounded.offer(1, bytes: 4_194_304) else { preconditionFailure() }
        guard case .overflow = bounded.offer(2, bytes: 1) else { preconditionFailure() }
        bounded.clear()
        _ = bounded.take()
        guard case .overflow = bounded.offer(3, bytes: -1) else { preconditionFailure() }
        guard case .schedule = bounded.offer(4, bytes: 2) else { preconditionFailure() }
        precondition(bounded.take() == 4 && bounded.take() == nil)
        print("PASS actual queue: byte bound, negative cost rejection and clear capacity reset")
        print("NOT TESTED: real-time audio callback load, iPhone HFP, acoustic AEC or HUD")
    }
}
