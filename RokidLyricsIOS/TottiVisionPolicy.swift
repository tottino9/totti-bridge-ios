import Foundation

/// Explicit requests only. Talking about photographs does not open the camera.
enum TottiVisionPolicy {
    static let maxJPEGBytes = 1_200_000
    static func requestsCapture(_ text: String) -> Bool {
        let normalized = text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).joined()
        if ["しない", "しなく", "しないで", "撮らない", "撮るな", "撮らず", "撮影禁止", "撮影しない", "見ないで"].contains(where: normalized.contains) { return false }
        if ["これ何", "これは何", "これなに", "これはなに", "これって何", "これってなに", "何が見える", "なにが見える"].contains(normalized) { return true }
        let photograph = normalized.contains("写真") || normalized.contains("撮影")
        let action = ["撮って", "撮影して", "見て", "説明して", "解析して", "分析して", "読んで"].contains(where: normalized.contains)
        let current = ["目の前", "見えている", "見えてる", "これを", "これが"].contains(where: normalized.contains)
        let explain = ["説明して", "教えて", "読んで", "何か", "なにか"].contains(where: normalized.contains)
        return photograph && action || current && explain
    }
    static func imageDataURL(_ data: Data) throws -> String {
        guard data.count >= 4, data.count <= maxJPEGBytes,
              data.prefix(3) == Data([0xff, 0xd8, 0xff]), data.suffix(2) == Data([0xff, 0xd9]) else {
            throw Failure.invalidImage
        }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
    enum Failure: LocalizedError {
        case invalidImage
        var errorDescription: String? { "眼鏡の写真データの形式またはサイズを確認できませんでした。" }
    }
}
