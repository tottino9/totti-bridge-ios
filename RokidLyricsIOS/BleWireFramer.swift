import Foundation

enum BleWireFramer {
    private static let version: UInt8 = 1
    private static let headerSize = 9

    static func encode(message: String, messageId: UInt32, maxPacketSize: Int) -> [Data] {
        let bytes = Array((message + "\n").utf8)
        let payloadSize = max(1, maxPacketSize - headerSize)
        let chunkCount = max(1, (bytes.count + payloadSize - 1) / payloadSize)
        guard chunkCount <= Int(UInt16.max) else { return [] }

        return (0..<chunkCount).map { index in
            let start = index * payloadSize
            let end = min(start + payloadSize, bytes.count)
            var frame = Data([
                version,
                UInt8((messageId >> 24) & 0xFF),
                UInt8((messageId >> 16) & 0xFF),
                UInt8((messageId >> 8) & 0xFF),
                UInt8(messageId & 0xFF),
                UInt8((index >> 8) & 0xFF),
                UInt8(index & 0xFF),
                UInt8((chunkCount >> 8) & 0xFF),
                UInt8(chunkCount & 0xFF)
            ])
            frame.append(contentsOf: bytes[start..<end])
            return frame
        }
    }

    final class Reassembler {
        private struct PendingMessage {
            var chunkCount: Int
            var chunks: [Data?]
        }

        private var pending: [UInt32: PendingMessage] = [:]

        func accept(_ frame: Data) -> String? {
            let bytes = Array(frame)
            guard bytes.count >= BleWireFramer.headerSize, bytes[0] == BleWireFramer.version else { return nil }
            let messageId = UInt32(bytes[1]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 8 | UInt32(bytes[4])
            let chunkIndex = Int(bytes[5]) << 8 | Int(bytes[6])
            let chunkCount = Int(bytes[7]) << 8 | Int(bytes[8])
            guard chunkCount > 0, chunkIndex >= 0, chunkIndex < chunkCount else { return nil }

            let payload = Data(bytes[BleWireFramer.headerSize..<bytes.count])
            var entry = pending[messageId] ?? PendingMessage(chunkCount: chunkCount, chunks: Array(repeating: nil, count: chunkCount))
            guard entry.chunkCount == chunkCount else {
                pending.removeValue(forKey: messageId)
                return nil
            }

            entry.chunks[chunkIndex] = payload
            pending[messageId] = entry
            guard entry.chunks.allSatisfy({ $0 != nil }) else { return nil }

            pending.removeValue(forKey: messageId)
            let messageData = entry.chunks.reduce(into: Data()) { partial, chunk in
                partial.append(chunk ?? Data())
            }
            return String(data: messageData, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        }

        func clear() {
            pending.removeAll()
        }
    }
}
