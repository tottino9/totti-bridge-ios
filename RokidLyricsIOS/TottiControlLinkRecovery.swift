import Foundation

/// Recovers only on fresh two-way control proof. Real HFP loss remains a
/// separate immediate failure. Repeated SDK false events never extend a probe.
@MainActor
final class TottiControlLinkRecovery {
    private let active:()->Bool
    private let probe:(String)->Void
    private let diagnostic:(String)->Void
    private let failed:(String)->Void
    private let now:()->TimeInterval
    private let pause:(UInt64) async throws -> Void
    private var policy=TottiControlProbePolicy()
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private var reportedConnected=true
    init(active:@escaping ()->Bool,probe:@escaping (String)->Void,
         diagnostic:@escaping (String)->Void,failed:@escaping (String)->Void,
         now:@escaping ()->TimeInterval={ProcessInfo.processInfo.systemUptime},
         pause:@escaping (UInt64) async throws -> Void={try await Task.sleep(nanoseconds:$0)}) {
        self.active=active;self.probe=probe;self.diagnostic=diagnostic;self.failed=failed
        self.now=now;self.pause=pause
    }
    func connected(){reportedConnected=true;cancel()}
    func cancel(){generation=UUID();task?.cancel();task=nil;policy.cancel()}
    func acknowledge(_ nonce:String)->Bool {
        guard active(),policy.acknowledge(nonce) else {return false}
        diagnostic("CONTROL_ROUND_TRIP_OK");return true
    }
    func disconnected(reason:String){
        reportedConnected=false
        guard active(),task == nil else {return}
        let token=UUID();generation=token
        diagnostic("SDK_FALSE reason="+reason)
        task=Task { @MainActor [weak self] in
            guard let self else {return}
            while !Task.isCancelled && self.generation == token && !self.reportedConnected && self.active(){
                let nonce=UUID().uuidString
                self.policy.issue(nonce,at:self.now())
                var attempts=0
                while !Task.isCancelled && self.generation == token && self.policy.pending == nonce {
                    if self.policy.expired(nonce,at:self.now()) {
                        self.policy.cancel()
                        self.diagnostic("CONTROL_PROBE_TIMEOUT")
                        self.failed("controlRoundTripTimeout/"+reason)
                        if self.generation == token {self.task=nil}
                        return
                    }
                    if attempts<3 {self.probe(nonce);attempts += 1}
                    do {try await self.pause(1_000_000_000)} catch {return}
                }
                guard !Task.isCancelled,self.generation == token,self.active() else {break}
                do {try await self.pause(2_000_000_000)} catch {return}
            }
            guard self.generation == token else {return}
            self.policy.cancel();self.task=nil
        }
    }
}
