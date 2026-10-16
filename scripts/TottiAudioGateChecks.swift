import Foundation

@main
struct TottiAudioGateChecks {
    @MainActor static func main() {
        var suspensions = 0
        TottiAudioGate.suspendLegacyAudio = {
            precondition(!TottiAudioGate.isHeld)
            suspensions += 1
        }
        precondition(TottiAudioGate.acquire("record:A"))
        precondition(TottiAudioGate.acquire("record:A"))
        precondition(suspensions == 1)
        precondition(!TottiAudioGate.acquire("speech:B"))
        TottiAudioGate.release("record:old")
        precondition(TottiAudioGate.isHeld)
        TottiAudioGate.release("record:A")
        precondition(!TottiAudioGate.isHeld)
        precondition(TottiAudioGate.acquire("speech:B"))
        precondition(suspensions == 2)
        TottiAudioGate.release("speech:B")
        precondition(TottiAudioGate.acquire("record:C"))
        TottiAudioGate.retainConversation()
        TottiAudioGate.release("record:C")
        precondition(TottiAudioGate.isHeld)
        let retainedSuspensions = suspensions
        for n in 0..<100 {
            precondition(TottiAudioGate.acquire("speech:\(n)"))
            precondition(!TottiAudioGate.acquire("record:\(n)"))
            TottiAudioGate.release("speech:\(n)")
            precondition(TottiAudioGate.acquire("record:\(n)"))
            TottiAudioGate.release("record:\(n)")
        }
        precondition(suspensions == retainedSuspensions)
        TottiAudioGate.endConversation()
        precondition(!TottiAudioGate.isHeld)
        precondition(TottiAudioGate.acquire("record:reconnect"))
        precondition(suspensions == retainedSuspensions + 1)
        TottiAudioGate.release("record:reconnect")
        precondition(TottiControlPausePolicy.mayContinueHFP(reason: "screenOffGlass"))
        precondition(TottiControlPausePolicy.mayContinueHFP(reason: "glassIdle"))
        for reason in [nil, "aiStart", "scenesTakeover", "linkDisconnected", "other"] as [String?] {
            precondition(!TottiControlPausePolicy.mayContinueHFP(reason: reason))
        }
        print("PASS: exclusive audio ownership, stale release, handoff, conservative pause policy")
    }
}
