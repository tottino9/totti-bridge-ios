import Foundation
import Dispatch
// Platform test double, like the audio/UI doubles below. Keep the coordinator's
// monotonic timing contract without initializing host process metadata.
enum ProcessInfo {
 struct Clock {var systemUptime:TimeInterval {Double(DispatchTime.now().uptimeNanoseconds)/1e9}}
 static let processInfo=Clock()
}
@MainActor final class AVAudioSession {
    enum Permission { case granted,denied,undetermined }
    enum Port { case bluetoothHFP,builtInMic }
    enum Category { case playAndRecord }
    enum Mode { case voiceChat }
    struct Options:OptionSet { let rawValue:Int; static let allowBluetooth=Options(rawValue:1) }
    static let value=AVAudioSession()
    static func sharedInstance()->AVAudioSession { value }
    var recordPermission=Permission.granted
    var availableInputs:[AVAudioSessionPortDescription]?=[.init()]
    var currentRoute=Route()
    struct Route { var inputs=[AVAudioSessionPortDescription()] }
    func requestRecordPermission(_ callback:(Bool)->Void) { callback(true) }
    func setCategory(_ value:Category,mode:Mode,options:Options) throws {}
    func setActive(_ value:Bool) throws {}
    func setPreferredInput(_ value:AVAudioSessionPortDescription) throws {}
}
struct AVAudioSessionPortDescription { var uid="rokid";var portName="Rokid Glasses";var portType=AVAudioSession.Port.bluetoothHFP }
@MainActor final class UIApplication {
    enum State {case active}
    static let shared=UIApplication();var applicationState=State.active
}
@MainActor final class TottiDuplexAudio {
    static let shared=TottiDuplexAudio()
    var isRunning=false
    var receive:((Data)->Void)?
    var failed:((String)->Void)?
    var starts=0
    func start() throws {if !isRunning { starts += 1 };isRunning=true}
    func stop(){isRunning=false}
}
@MainActor enum TottiConversationAudio {
 static func end(){TottiDuplexAudio.shared.stop();TottiAudioGate.endConversation()}
}
@MainActor final class TottiVoiceRelay {
 var onSpeechPlaybackChanged:((Bool)->Void)?
 var speakingRequestID:String?
 var sessionEnded=false
 var isBusy=false
 var hasAskedToEnd=false
 var submitted:[(String,Data)]=[]
 var interrupts=0
 func acceptSession(_ id:String)->Bool{!sessionEnded}
 func noteCaptureRequest(){}
 func promptAfterSilence(_ id:String){hasAskedToEnd=true}
 func submitCaptured(_ id:String,wav:Data){isBusy=true;submitted.append((id,wav))}
 func cancelCaptured(_ id:String){isBusy=false}
 func connectionLost(){isBusy=false}
 func interruptSpeech(){interrupts += 1;isBusy=false;onSpeechPlaybackChanged?(false)}
 func play(_ id:String){isBusy=true;speakingRequestID=id;onSpeechPlaybackChanged?(true)}
}
@main struct CaptureHarness {
 @MainActor static func settle() async {
  for _ in 0..<2000 {
   if TottiDuplexAudio.shared.isRunning {return}
   try? await Task.sleep(nanoseconds:1_000_000)
  }
  precondition(TottiDuplexAudio.shared.isRunning,"Capture startup did not settle")
 }
 @MainActor static func main() async {
  let relay=TottiVoiceRelay();var sent:[[String:Any]]=[]
  let capture=TottiHFPCapture(send:{sent.append($0)},relay:relay)
  func start(_ id:String){precondition(capture.handle(["type":"totti_mic_start","request_id":id,"session_id":"test"]))}
  func feed(_ amplitude:Int16,_ n:Int){
   let v=UInt16(bitPattern:amplitude);var data=Data()
   for _ in 0..<320 {data.append(UInt8(v & 255));data.append(UInt8(v >> 8))}
   for _ in 0..<n {TottiDuplexAudio.shared.receive?(data)}
  }
  start("first");await settle()
  precondition(sent.isEmpty,"No premature ready before PCM")
  feed(0,9);precondition(sent.isEmpty)
  feed(0,1);precondition(sent.count==1 && sent[0]["type"] as? String == "totti_listening")
  feed(1000,8);feed(0,60)
  precondition(relay.submitted.count==1 && relay.submitted[0].0=="first")
  relay.play("first")
  precondition(sent.last?["type"] as? String == "totti_listening","Reading allows voice input")
  feed(1000,8);precondition(relay.interrupts==1,"Speech onset cancels reading once")
  feed(0,60)
  precondition(relay.submitted.count==1,"No upload under completed answer's ID")
  start("second");await settle();feed(0,10)
  precondition(relay.submitted.count==2 && relay.submitted[1].0=="second","Buffered interruption transferred to next request")
  precondition(relay.submitted[1].1.contains(232),"Original voiced PCM retained through delayed control handoff")
  precondition(TottiDuplexAudio.shared.starts==1,"No graph restart for interruption handoff")
  relay.isBusy=false
  start("third");await settle();feed(0,10)
  precondition(relay.submitted.count==2,"Completed segment cannot be submitted twice")
  relay.sessionEnded=true;feed(0,1)
  precondition(!TottiDuplexAudio.shared.isRunning,"Session exit stops microphone graph")
  print("PASS actual capture coordinator: PCM-gated ready, single interruption, delayed request-ID handoff, preserved speech, no duplicate upload, session close")
 }
}
