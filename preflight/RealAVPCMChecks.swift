// Apple SDK execution target. NOT executable in the Linux fixture harness.
import AVFoundation
import Foundation
@main struct RealAVPCMChecks {
 static func main()throws {
  for common in [AVAudioCommonFormat.pcmFormatInt16,.pcmFormatFloat32] {
   for channels:AVAudioChannelCount in [1,2] {for interleaved in [false,true] {
    let format=AVAudioFormat(commonFormat:common,sampleRate:44100,channels:channels,interleaved:interleaved)!
    let source=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!
    source.frameLength=17
    let bytes=Int(source.frameLength*format.streamDescription.pointee.mBytesPerFrame)
    let planes=UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    var expected:[Data]=[]
    for (i,plane) in planes.enumerated(){
     let p=plane.mData!.assumingMemoryBound(to:UInt8.self)
     for j in 0..<bytes{p[j]=UInt8((i*31+j)%251)}
     expected.append(Data(bytes:p,count:bytes))
    }
    let mutableSize=source.mutableAudioBufferList.pointee.mBuffers.mDataByteSize
    let readableSize=source.audioBufferList.pointee.mBuffers.mDataByteSize
    print("OBSERVED real SDK metadata common=\(common.rawValue) channels=\(channels) interleaved=\(interleaved) mutableBytes=\(mutableSize) readableBytes=\(readableSize)")
    let copy=TottiSpeechPCM.copy(source)!
    precondition(copy.frameLength==17 && TottiSpeechPCM.byteCount(copy)==bytes*planes.count)
    let copied=UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for i in 0..<planes.count{
     planes[i].mData!.initializeMemory(as:UInt8.self,repeating:0xee,count:bytes)
     precondition(Data(bytes:copied[i].mData!,count:bytes)==expected[i])
    }
    source.frameLength=0
    precondition(TottiSpeechPCM.copy(source)?.frameLength==0 && TottiSpeechPCM.byteCount(source)==0)
    print("PASS real AVFoundation payload/independence/end-marker common=\(common.rawValue) channels=\(channels) interleaved=\(interleaved)")
   }}
  }
  print("NOT TESTED: iPhone HFP, acoustic AEC, CXR/HUD or restored installation")
 }
}
