import Foundation

struct WireEnvelope: Codable, Equatable {
    var channel: String
    var type: String
    var payloadJson: String?
}

enum GlassesToPhoneMessage: Equatable {
    case hello(ProtocolHello)
    case requestSnapshot
    case requestStatus
    case togglePlayback
}

enum LyricsEvent: Equatable {
    case snapshot(LyricsSnapshot)
    case sync(LyricsPlaybackSync)
    case error(String)
}

enum PhoneToGlassesMessage: Equatable {
    case helloAck(ProtocolHelloAck)
    case status(DeviceStatus)
    case lyrics(LyricsEvent)
    case error(String)
}

enum WireProtocol {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func encodeGlassesMessage(_ message: GlassesToPhoneMessage) throws -> String {
        try encodeEnvelope(glassesEnvelope(for: message))
    }

    static func decodeGlassesMessage(_ json: String) -> GlassesToPhoneMessage? {
        guard let envelope = decodeEnvelope(json) else { return nil }
        return glassesMessage(for: envelope)
    }

    static func encodePhoneMessage(_ message: PhoneToGlassesMessage) throws -> String {
        try encodeEnvelope(phoneEnvelope(for: message))
    }

    static func decodePhoneMessage(_ json: String) -> PhoneToGlassesMessage? {
        guard let envelope = decodeEnvelope(json) else { return nil }
        return phoneMessage(for: envelope)
    }

    private static func glassesEnvelope(for message: GlassesToPhoneMessage) throws -> WireEnvelope {
        switch message {
        case .hello(let hello):
            return try WireEnvelope(channel: "runtime", type: "hello", payloadJson: payload(hello))
        case .requestSnapshot:
            return WireEnvelope(channel: "runtime", type: "request_snapshot")
        case .requestStatus:
            return WireEnvelope(channel: "runtime", type: "request_status")
        case .togglePlayback:
            return WireEnvelope(channel: "runtime", type: "toggle_playback")
        }
    }

    private static func glassesMessage(for envelope: WireEnvelope) -> GlassesToPhoneMessage? {
        guard envelope.channel == "runtime" else { return nil }
        switch envelope.type {
        case "hello":
            return decodePayload(ProtocolHello.self, envelope.payloadJson).map(GlassesToPhoneMessage.hello)
        case "request_snapshot":
            return .requestSnapshot
        case "request_status":
            return .requestStatus
        case "toggle_playback":
            return .togglePlayback
        default:
            return nil
        }
    }

    private static func phoneEnvelope(for message: PhoneToGlassesMessage) throws -> WireEnvelope {
        switch message {
        case .helloAck(let ack):
            return try WireEnvelope(channel: "runtime", type: "hello_ack", payloadJson: payload(ack))
        case .status(let status):
            return try WireEnvelope(channel: "runtime", type: "status", payloadJson: payload(status))
        case .lyrics(let event):
            switch event {
            case .snapshot(let snapshot):
                return try WireEnvelope(channel: "lyrics", type: "snapshot", payloadJson: payload(snapshot))
            case .sync(let sync):
                return try WireEnvelope(channel: "lyrics", type: "sync", payloadJson: payload(sync))
            case .error(let message):
                return try WireEnvelope(channel: "lyrics", type: "error", payloadJson: payload(ErrorPayload(message: message)))
            }
        case .error(let message):
            return try WireEnvelope(channel: "runtime", type: "error", payloadJson: payload(ErrorPayload(message: message)))
        }
    }

    private static func phoneMessage(for envelope: WireEnvelope) -> PhoneToGlassesMessage? {
        switch (envelope.channel, envelope.type) {
        case ("runtime", "hello_ack"):
            return decodePayload(ProtocolHelloAck.self, envelope.payloadJson).map(PhoneToGlassesMessage.helloAck)
        case ("runtime", "status"):
            return decodePayload(DeviceStatus.self, envelope.payloadJson).map(PhoneToGlassesMessage.status)
        case ("runtime", "error"):
            return decodePayload(ErrorPayload.self, envelope.payloadJson).map { .error($0.message) }
        case ("lyrics", "snapshot"):
            return decodePayload(LyricsSnapshot.self, envelope.payloadJson).map { .lyrics(.snapshot($0)) }
        case ("lyrics", "sync"):
            return decodePayload(LyricsPlaybackSync.self, envelope.payloadJson).map { .lyrics(.sync($0)) }
        case ("lyrics", "error"):
            return decodePayload(ErrorPayload.self, envelope.payloadJson).map { .lyrics(.error($0.message)) }
        default:
            return nil
        }
    }

    private static func payload<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func encodeEnvelope(_ envelope: WireEnvelope) throws -> String {
        let data = try encoder.encode(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeEnvelope(_ json: String) -> WireEnvelope? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(WireEnvelope.self, from: data)
    }

    private static func decodePayload<T: Decodable>(_ type: T.Type, _ payloadJson: String?) -> T? {
        guard let payloadJson, let data = payloadJson.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}

private struct ErrorPayload: Codable, Equatable {
    var message: String
}
