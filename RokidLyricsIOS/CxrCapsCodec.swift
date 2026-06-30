import Foundation

/// Rokid "Caps" v5 wire format codec (matches RGCxrCore/caps.cpp).
///
/// Layout: `[4-byte big-endian totalSize][1-byte version=0x05][uleb128 memberCount]`
/// `[memberCount type bytes][per member: uleb128(byteLen) + bytes]`.
/// String ('S'=0x53) and binary ('B'=0x42) members share the `uleb128(len)+bytes` body.
///
/// The glasses app reads the custom-command payload as a Caps and pulls a binary member
/// (it logs `bytesSize`), so phone→glasses sends a single binary member. Decoding accepts a
/// Caps with any string/binary member, and falls back to raw UTF-8 if the bytes are not a Caps.
enum CxrCapsCodec {
    private static let version: UInt8 = 5
    private static let typeString: UInt8 = 0x53 // 'S'
    private static let typeBinary: UInt8 = 0x42 // 'B'

    /// Wrap `payload` as a Caps v5 blob with a single binary member.
    static func encodeBinaryPayload(_ payload: Data) -> Data {
        var body = Data()
        body.append(version)
        appendUleb128(1, to: &body) // member count
        body.append(typeBinary) // member type descriptor
        appendUleb128(payload.count, to: &body)
        body.append(payload)

        var packet = Data()
        var total = UInt32(body.count + 4).bigEndian
        withUnsafeBytes(of: &total) { packet.append(contentsOf: $0) }
        packet.append(body)
        return packet
    }

    /// Extract the JSON string from a received payload. Tries to parse a Caps v5 blob and return
    /// the first string/binary member that looks like JSON; falls back to treating the whole
    /// payload as raw UTF-8.
    static func decodeJSONPayload(_ data: Data) -> String? {
        if let members = parseCapsMembers(data) {
            // Prefer a member that decodes to a JSON object, else the last decodable member.
            var fallback: String?
            for member in members {
                guard let string = String(data: member, encoding: .utf8) else { continue }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                    return string
                }
                fallback = string
            }
            if let fallback { return fallback }
        }
        // Not a Caps (or unparsable) — treat as raw UTF-8 JSON.
        if let raw = String(data: data, encoding: .utf8) {
            return raw
        }
        return nil
    }

    /// Parse a Caps v5 blob into its member byte payloads. Returns nil if the bytes are not a
    /// well-formed Caps.
    private static func parseCapsMembers(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count > 5 else { return nil }
        let totalSize = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        guard bytes[4] == version, Int(totalSize) == bytes.count else { return nil }

        var offset = 5
        guard let count = readUleb128(bytes, offset: &offset), count >= 1, count < 64 else { return nil }
        let typeStart = offset
        offset += count
        guard offset <= bytes.count else { return nil }
        let types = Array(bytes[typeStart ..< offset])

        var members: [Data] = []
        for type in types {
            guard type == typeString || type == typeBinary else { return nil }
            guard let length = readUleb128(bytes, offset: &offset),
                  offset + length <= bytes.count else { return nil }
            members.append(Data(bytes[offset ..< offset + length]))
            offset += length
        }
        return members
    }

    private static func appendUleb128(_ value: Int, to data: inout Data) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remaining != 0
    }

    private static func readUleb128(_ bytes: [UInt8], offset: inout Int) -> Int? {
        var shift = 0
        var result = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
            if shift > 28 {
                return nil
            }
        }
        return nil
    }
}
