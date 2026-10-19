import Foundation
import UIKit

/// One SDK capture at a time. Timeout/cancel invalidate late callbacks.
/// Does not change Bluetooth or AVAudioSession configuration.
@MainActor
final class TottiVisionCapture {
    typealias Start = (Int, Int, Int, @escaping (Data) -> Void) -> String?
    private let start: Start
    private var pending: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = 0

    init(start: @escaping Start) { self.start = start }

    func jpeg() async throws -> Data {
        try Task.checkCancellation()
        guard pending == nil else { throw Failure.message("前の写真を取得中です。") }
        generation += 1
        let token = generation
        let raw: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: 25_000_000_000) } catch { return }
                    self?.finish(token, .failure(Failure.message("眼鏡の写真が25秒以内に届きませんでした。カメラの利用許可とRokidアプリの接続を確認してください。")))
                }
                let error = start(1280, 720, 75) { [weak self] bytes in
                    Task { @MainActor in self?.finish(token, .success(bytes)) }
                }
                if let error { finish(token, .failure(Failure.message("眼鏡の撮影を開始できませんでした: " + error))) }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.finish(token, .failure(CancellationError())) }
        })
        try Task.checkCancellation()
        guard raw.count <= 5_000_000, let original = UIImage(data: raw),
              original.size.width > 0, original.size.height > 0,
              original.size.width <= 8192, original.size.height <= 8192 else { throw TottiVisionPolicy.Failure.invalidImage }
        let factor = min(1, 1280 / max(original.size.width, original.size.height))
        let size = CGSize(width: max(1, original.size.width * factor), height: max(1, original.size.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = image.jpegData(compressionQuality: 0.72) else { throw TottiVisionPolicy.Failure.invalidImage }
        _ = try TottiVisionPolicy.imageDataURL(jpeg)
        return jpeg
    }
    private func finish(_ token: Int, _ result: Result<Data, Error>) {
        guard token == generation, let continuation = pending else { return }
        pending = nil
        timeout?.cancel()
        timeout = nil
        continuation.resume(with: result)
    }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}
