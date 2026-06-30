import Foundation

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? String { return Int(value) }
        return nil
    }

    func int64(_ key: String) -> Int64? {
        if let value = self[key] as? Int64 { return value }
        if let value = self[key] as? Int { return Int64(value) }
        if let value = self[key] as? Double { return Int64(value) }
        if let value = self[key] as? String { return Int64(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? Int { return Double(value) }
        if let value = self[key] as? Int64 { return Double(value) }
        if let value = self[key] as? String { return Double(value) }
        return nil
    }

    func truthy(_ key: String) -> Bool {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? Int { return value != 0 }
        if let value = self[key] as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

extension String {
    func ifBlank(_ fallback: String) -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : self
    }

    func takeUnlessBlank() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }

    func cleanLyricText() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    func sanitizedMusicText() -> String {
        replacingOccurrences(of: "\u{ff08}", with: "(")
            .replacingOccurrences(of: "\u{ff09}", with: ")")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
