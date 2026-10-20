import Foundation
@MainActor final class Fixture {
 var active=true,time=0.0,sleeps=0
 var nonces:[String]=[],diagnostics:[String]=[],failures:[String]=[]
 var onProbe:((String)->Void)?
 var onSleep:(()->Void)?
 var recovery:TottiControlLinkRecovery!
 init(){
  recovery=TottiControlLinkRecovery(active:{[weak self] in self?.active == true},
   probe:{[weak self] nonce in self?.nonces.append(nonce);self?.onProbe?(nonce)},
   diagnostic:{[weak self] text in self?.diagnostics.append(text)},
   failed:{[weak self] text in self?.failures.append(text)},
   now:{[weak self] in self?.time ?? 0},
   pause:{[weak self] ns in
    guard let self else {throw CancellationError()}
    self.time += Double(ns)/1e9;self.sleeps += 1
    precondition(self.sleeps < 100,"Recovery must remain bounded")
    self.onSleep?();await Task.yield();try Task.checkCancellation()
   })
 }
}
@main struct TottiControlRecoveryChecks {
 @MainActor static func until(_ done:()->Bool) async {
  for _ in 0..<2000 {if done(){return};try? await Task.sleep(nanoseconds:1_000_000)}
  precondition(done(),"Asynchronous coordinator did not settle")
 }
 @MainActor static func main() async {
  let healthy=Fixture()
  healthy.onProbe={nonce in precondition(healthy.recovery.acknowledge(nonce));healthy.active=false}
  healthy.recovery.disconnected(reason:"sdkFalse");await until{!healthy.active && healthy.nonces.count==1}
  precondition(healthy.nonces.count==1 && healthy.failures.isEmpty)
  precondition(healthy.diagnostics.contains("CONTROL_ROUND_TRIP_OK"))
  healthy.recovery.cancel()

  let lost=Fixture()
  lost.onSleep={lost.recovery.disconnected(reason:"repeatedFalse")}
  lost.recovery.disconnected(reason:"sdkFalse");await until{!lost.failures.isEmpty}
  precondition(lost.failures==["controlRoundTripTimeout/sdkFalse"])
  precondition(lost.time==6 && lost.nonces.count==3)
  precondition(Set(lost.nonces).count==1,"Retries reuse challenge without extending deadline")
  lost.recovery.cancel()

  let restored=Fixture()
  var restoredDone=false
  restored.onSleep={restored.recovery.connected();restoredDone=true}
  restored.recovery.disconnected(reason:"sdkFalse");await until{restoredDone}
  precondition(restored.nonces.count==1 && restored.failures.isEmpty)
  precondition(!restored.recovery.acknowledge(restored.nonces[0]),"Old proof cannot revive cancelled probe")

  let idle=Fixture();idle.active=false
  idle.recovery.disconnected(reason:"sdkFalse")
  precondition(idle.nonces.isEmpty && idle.failures.isEmpty)

  let ended=Fixture()
  ended.onSleep={ended.active=false;ended.recovery.cancel()}
  ended.recovery.disconnected(reason:"sdkFalse");await until{!ended.active}
  precondition(ended.failures.isEmpty && !ended.recovery.acknowledge(ended.nonces[0]))

  let laterLoss=Fixture();var first:String?
  laterLoss.onProbe={nonce in
   if first == nil {first=nonce;precondition(laterLoss.recovery.acknowledge(nonce))}
   else {precondition(nonce != first,"Fresh proof required after earlier success")}
  }
  laterLoss.recovery.disconnected(reason:"sdkFalse");await until{!laterLoss.failures.isEmpty}
  precondition(laterLoss.failures.count==1,"One old success cannot mask later real link loss")
  laterLoss.recovery.cancel()
  print("PASS actual recovery coordinator: verified live path survives SDK false; real loss stops at 6s; repeated false cannot extend; reconnect/exit cancel; stale replies rejected; proof must renew")
 }
}
