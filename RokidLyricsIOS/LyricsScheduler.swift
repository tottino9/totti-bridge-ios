import Foundation

struct LyricsScheduleWindow: Equatable {
    var previous: LyricsLine?
    var current: LyricsLine?
    var next: LyricsLine?
    var currentIndex: Int
}

enum LyricsScheduler {
    static func index(for lines: [LyricsLine], progressMs: Int64) -> Int {
        guard !lines.isEmpty else { return -1 }
        var low = 0
        var high = lines.count - 1
        var candidate = -1

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].startTimeMs <= progressMs {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return candidate
    }

    static func window(for lines: [LyricsLine], progressMs: Int64) -> LyricsScheduleWindow {
        let currentIndex = index(for: lines, progressMs: progressMs)
        let previousIndex = currentIndex - 1
        let nextIndex = currentIndex + 1
        return LyricsScheduleWindow(
            previous: lines.indices.contains(previousIndex) ? lines[previousIndex] : nil,
            current: lines.indices.contains(currentIndex) ? lines[currentIndex] : nil,
            next: lines.indices.contains(nextIndex) ? lines[nextIndex] : nil,
            currentIndex: currentIndex
        )
    }
}
