import Foundation

/// Serial ownership of the app's shared AVAudioSession. Background music polling
/// must not reconfigure or deactivate it while a Totti turn is using it.
@MainActor
enum TottiAudioGate {
    private(set) static var owner: String?
    static var suspendLegacyAudio: (() -> Void)?
    private(set) static var conversationActive = false
    static var isHeld: Bool { owner != nil || conversationActive }
    static func retainConversation() { conversationActive = true }
    static func endConversation() { conversationActive = false }

    static func acquire(_ id: String) -> Bool {
        if owner == id { return true }
        guard owner == nil else { return false }
        // Stop/deactivate the old engine before acquiring the recording session.
        if !conversationActive { suspendLegacyAudio?() }
        owner = id
        return true
    }
    static func release(_ id: String) {
        guard owner == id else { return }
        owner = nil
    }
}

enum TottiControlPausePolicy {
    // Only display sleep/idle is safe to ignore for independent HFP capture.
    // AI/scene takeover and unknown reasons must end capture explicitly.
    static func mayContinueHFP(reason: String?) -> Bool {
        reason == "screenOffGlass" || reason == "glassIdle"
    }
}
