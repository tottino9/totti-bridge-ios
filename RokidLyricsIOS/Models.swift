import Foundation

enum ConnectionState: String, Codable, Equatable {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
}

struct DeviceStatus: Codable, Equatable {
    var connectionState: ConnectionState = .disconnected
    var statusLabel: String = "Waiting for the iOS runtime."
    var bluetoothClientCount: Int = 0
    var notificationAccessEnabled: Bool = false
    var lastError: String?
}

enum LyricsSessionState: String, Codable, Equatable {
    case idle = "IDLE"
    case loading = "LOADING"
    case ready = "READY"
    case playing = "PLAYING"
    case error = "ERROR"
}

struct LyricsLine: Codable, Equatable, Identifiable {
    var id: Int64 { startTimeMs }
    var startTimeMs: Int64 = 0
    var text: String = ""
}

struct LyricsSnapshot: Codable, Equatable {
    var sessionState: LyricsSessionState = .idle
    var mediaKey: String = ""
    var revision: Int64 = 0
    var trackTitle: String = ""
    var artistName: String = ""
    var albumName: String = ""
    var durationSeconds: Int?
    var provider: String = ""
    var sourceSummary: String = "Waiting for a track lookup."
    var synced: Bool = false
    var progressMs: Int64 = 0
    var capturedAtEpochMs: Int64 = 0
    var currentLineIndex: Int = -1
    var lines: [LyricsLine] = []
    var plainLyrics: String = ""
    var errorMessage: String?
}

struct LyricsPlaybackSync: Codable, Equatable {
    var sessionState: LyricsSessionState = .idle
    var mediaKey: String = ""
    var revision: Int64 = 0
    var progressMs: Int64 = 0
    var capturedAtEpochMs: Int64 = 0
    var currentLineIndex: Int = -1
}

struct ProtocolHello: Codable, Equatable {
    var protocolVersion: Int = TransportConstants.protocolVersion
    var appVersion: String = ""
    var capabilities: [String] = []
}

struct ProtocolHelloAck: Codable, Equatable {
    var protocolVersion: Int = TransportConstants.protocolVersion
    var appVersion: String = ""
    var capabilities: [String] = []
}

enum TransportConstants {
    static let bluetoothServiceName = "RokidLyricsBT"
    static let sppUUID = "f77d5d54-cfee-4d8c-b0d0-02cf6f5478aa"
    static let bleServiceUUID = "0f2d83d0-7f55-43a5-9f12-593fb4b70a01"
    static let bleRXCharacteristicUUID = "0f2d83d1-7f55-43a5-9f12-593fb4b70a01"
    static let bleTXCharacteristicUUID = "0f2d83d2-7f55-43a5-9f12-593fb4b70a01"
    static let protocolVersion = 2
}

struct LyricsLookupRequest: Equatable {
    var title: String
    var artist: String
    var album: String = ""
    var durationSeconds: Int?
    var isrc: String?
}

struct LyricsFetchResult: Equatable {
    var trackTitle: String
    var artistName: String
    var albumName: String
    var durationSeconds: Int?
    var provider: String
    var synced: Bool
    var lines: [LyricsLine]
    var plainLyrics: String
    var sourceSummary: String
}

struct MediaPlaybackSnapshot: Equatable {
    var source: String
    var trackId: String
    var title: String
    var artist: String
    var album: String
    var durationSeconds: Int?
    var positionMs: Int64
    var isPlaying: Bool
    var isrc: String?

    var lookupRequest: LyricsLookupRequest {
        LyricsLookupRequest(
            title: title,
            artist: artist,
            album: album,
            durationSeconds: durationSeconds,
            isrc: isrc
        )
    }

    var lookupKey: String {
        [
            source,
            trackId,
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            durationSeconds.map(String.init) ?? ""
        ].joined(separator: "|")
    }
}
