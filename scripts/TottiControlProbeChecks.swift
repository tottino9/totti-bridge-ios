import Foundation
@main struct TottiControlProbeChecks {
 static func main(){
  var p=TottiControlProbePolicy()
  precondition(!p.acknowledge("unsolicited"))
  p.issue("first",at:0)
  precondition(!p.expired("first",at:5.99))
  precondition(p.expired("first",at:6))
  precondition(!p.acknowledge("wrong"))
  precondition(p.pending == "first")
  precondition(p.acknowledge("first"))
  precondition(!p.expired("first",at:100))
  precondition(!p.acknowledge("first"))
  p.issue("old",at:100);p.cancel();p.issue("new",at:101)
  precondition(!p.acknowledge("old"),"Delayed reply from old session cannot rescue new one")
  precondition(!p.expired("old",at:1000))
  precondition(p.expired("new",at:107))
  p.cancel();precondition(!p.expired("new",at:1000))
  for n in 0..<100 {
   p.issue("old-\(n)",at:Double(n));p.cancel();p.issue("new-\(n)",at:Double(n))
   precondition(!p.acknowledge("old-\(n)"));precondition(p.acknowledge("new-\(n)"))
  }
  print("PASS control proof: fresh nonce only, exact six-second deadline, no stale reply revival, cancellation, 100 generations")
 }
}
