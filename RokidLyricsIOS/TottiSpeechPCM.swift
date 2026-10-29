#if TOTTI_EXPERIMENTAL_DUPLEX
import AVFoundation
import Foundation

enum TottiSpeechPCM {
    // Derive valid payload from frameLength/stride, and treat mDataByteSize as a bound.
    // Xcode 16.4's real AV test reported frame-sized byte counts for both list accessors.
    private static func bytesPerBuffer(_ input:AVAudioPCMBuffer) -> Int? {
        let stride=Int(input.format.streamDescription.pointee.mBytesPerFrame)
        let (bytes,overflow)=Int(input.frameLength).multipliedReportingOverflow(by:stride)
        guard !overflow,stride>0,input.frameLength<=input.frameCapacity else{return nil}
        return bytes
    }
    static func copy(_ input:AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let length=bytesPerBuffer(input),
              let output=AVAudioPCMBuffer(pcmFormat:input.format,frameCapacity:max(input.frameLength,1)) else{return nil}
        output.frameLength=input.frameLength
        let source=UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
        let target=UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let expected=input.format.isInterleaved ? 1:Int(input.format.channelCount)
        guard expected>0,source.count==expected,target.count==expected else{return nil}
        for i in 0..<source.count {
            guard length<=Int(source[i].mDataByteSize),length<=Int(target[i].mDataByteSize) else{return nil}
            if length>0 {
                guard let src=source[i].mData,let dst=target[i].mData else{return nil}
                memcpy(dst,src,length)
            }
        }
        return output
    }
    static func byteCount(_ input:AVAudioPCMBuffer) -> Int {
        guard let bytes=bytesPerBuffer(input) else{return Int.max}
        let count=UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList).count
        let (total,overflow)=bytes.multipliedReportingOverflow(by:count)
        return overflow ? Int.max:total
    }
}
#endif
