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
        precondition(TottiControlPausePolicy.mayContinueHFP(reason: "screenOffGlass"))
        precondition(TottiControlPausePolicy.mayContinueHFP(reason: "glassIdle"))
        for reason in [nil, "aiStart", "scenesTakeover", "linkDisconnected", "other"] as [String?] {
            precondition(!TottiControlPausePolicy.mayContinueHFP(reason: reason))
        }
        print("PASS: exclusive audio ownership, stale release, handoff, conservative pause policy")
    }
}
