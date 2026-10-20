import AVFoundation
import Foundation

@MainActor
enum TottiConversationAudio {
    static func end() {
        guard TottiAudioGate.conversationActive else { return }
        TottiDuplexAudio.shared.stop()
        TottiAudioGate.endConversation()
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { print("[TottiAudio] SESSION_RELEASE_FAILED \(error)") }
    }
}
