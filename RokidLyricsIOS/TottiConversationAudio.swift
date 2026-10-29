#if !TOTTI_EXPERIMENTAL_DUPLEX
import AVFoundation
import Foundation

@MainActor
enum TottiConversationAudio {
    static func end() {
        guard TottiAudioGate.conversationActive else { return }
        TottiAudioGate.endConversation()
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { print("[TottiAudio] SESSION_RELEASE_FAILED \(error)") }
    }
}
#else
import AVFoundation
import Foundation

@MainActor
enum TottiConversationAudio {
    static func end() {
        TottiDuplexAudio.shared.stop()
        guard TottiAudioGate.conversationActive else { return }
        TottiAudioGate.endConversation()
        do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        catch { print("[TottiAudio] SESSION_RELEASE_FAILED \(error)") }
    }
}
#endif
