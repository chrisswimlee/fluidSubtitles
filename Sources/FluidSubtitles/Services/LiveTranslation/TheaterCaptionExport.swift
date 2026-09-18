import Foundation

nonisolated enum TheaterCaptionExport {
    static func bilingualText(pairs: [CaptionHistoryPair]) -> String {
        pairs
            .compactMap(Self.cueText(for:))
            .joined(separator: "\n\n")
    }

    static func srt(pairs: [CaptionHistoryPair], secondsPerCue: Int = 4) -> String {
        Self.srt(cues: Self.cues(from: pairs, secondsPerCue: secondsPerCue))
    }

    static func vtt(pairs: [CaptionHistoryPair], secondsPerCue: Int = 4) -> String {
        Self.vtt(cues: Self.cues(from: pairs, secondsPerCue: secondsPerCue))
    }

    static func srt(entries: [LectureCaptionEntry], secondsPerCue: Int = 4) -> String {
        Self.srt(pairs: Self.pairs(from: entries), secondsPerCue: secondsPerCue)
    }

    static func vtt(entries: [LectureCaptionEntry], secondsPerCue: Int = 4) -> String {
        Self.vtt(pairs: Self.pairs(from: entries), secondsPerCue: secondsPerCue)
    }

    static func pairs(from entries: [LectureCaptionEntry]) -> [CaptionHistoryPair] {
        entries.map { entry in
            CaptionHistoryPair(
                source: entry.source,
                translated: entry.translated,
                wasPolished: entry.wasPolished,
                committedAt: Self.usableCommittedAt(entry.committedAt)
            )
        }
    }

    static func savePanelName(extension fileExtension: String) -> String {
        let stamp = Self.fileStamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "fluidSubtitles-\(stamp).\(fileExtension)"
    }

    private static let fileStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime]
        formatter.timeZone = .current
        return formatter
    }()

    private struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    private static func srt(cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            """
            \(index + 1)
            \(Self.srtTimestamp(cue.start)) --> \(Self.srtTimestamp(cue.end))
            \(cue.text)
            """
        }
        .joined(separator: "\n\n")
    }

    private static func vtt(cues: [Cue]) -> String {
        let body = cues.map { cue in
            """
            \(Self.vttTimestamp(cue.start)) --> \(Self.vttTimestamp(cue.end))
            \(cue.text)
            """
        }
        .joined(separator: "\n\n")
        return "WEBVTT\n\n\(body)"
    }

    private static func cues(from pairs: [CaptionHistoryPair], secondsPerCue: Int) -> [Cue] {
        let items: [(text: String, committedAt: Date?)] = pairs.compactMap { pair in
            guard let text = Self.cueText(for: pair) else { return nil }
            return (text, Self.usableCommittedAt(pair.committedAt))
        }
        guard !items.isEmpty else { return [] }
        let slot = TimeInterval(max(2, secondsPerCue))
        if let dates = Self.timelineDates(from: items.map(\.committedAt), slot: slot) {
            return Self.timedCues(texts: items.map(\.text), dates: dates, fallbackDuration: slot)
        }
        return items.enumerated().map { index, item in
            let start = TimeInterval(index) * slot
            return Cue(start: start, end: start + slot, text: item.text)
        }
    }

    /// `nil` and `.distantPast` (old archive JSON) are missing commit times.
    private static func usableCommittedAt(_ date: Date?) -> Date? {
        guard let date, date != .distantPast else { return nil }
        return date
    }

    /// Prefer real commit times. A few missing dates (legacy overflow) inherit
    /// the neighboring cue plus `slot` instead of forcing 4-second slots on the
    /// whole file.
    private static func timelineDates(from dates: [Date?], slot: TimeInterval) -> [Date]? {
        guard let firstValidIndex = dates.firstIndex(where: { $0 != nil }),
              let firstValid = dates[firstValidIndex]
        else { return nil }

        var filled: [Date] = []
        filled.reserveCapacity(dates.count)
        var last: Date?
        for (index, date) in dates.enumerated() {
            if let date {
                filled.append(date)
                last = date
            } else if let previous = last {
                let next = previous.addingTimeInterval(slot)
                filled.append(next)
                last = next
            } else {
                let back = firstValid.addingTimeInterval(-slot * Double(firstValidIndex - index))
                filled.append(back)
                last = back
            }
        }
        return filled
    }

    private static func timedCues(
        texts: [String],
        dates: [Date],
        fallbackDuration: TimeInterval
    ) -> [Cue] {
        guard let origin = dates.first else { return [] }
        return texts.enumerated().map { index, text in
            let start = max(0, dates[index].timeIntervalSince(origin))
            let end: TimeInterval
            if index + 1 < dates.count {
                end = max(start, dates[index + 1].timeIntervalSince(origin))
            } else if dates.count == 1 {
                end = start + fallbackDuration
            } else {
                let sincePrevious = dates[index].timeIntervalSince(dates[index - 1])
                let duration = min(12, max(2, sincePrevious))
                end = start + duration
            }
            return Cue(start: start, end: end, text: text)
        }
    }

    private static func cueText(for pair: CaptionHistoryPair) -> String? {
        let source = pair.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = pair.translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty, target.isEmpty { return nil }
        if source.isEmpty { return target }
        if target.isEmpty || source == target { return target.isEmpty ? source : target }
        return "\(target)\n\(source)"
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        Self.timestamp(seconds, fraction: ",")
    }

    private static func vttTimestamp(_ seconds: TimeInterval) -> String {
        Self.timestamp(seconds, fraction: ".")
    }

    private static func timestamp(_ seconds: TimeInterval, fraction: String) -> String {
        let totalMilliseconds = max(0, Int((seconds * 1_000).rounded()))
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let remainder = (totalMilliseconds % 60_000) / 1_000
        let milliseconds = totalMilliseconds % 1_000
        return String(
            format: "%02d:%02d:%02d\(fraction)%03d",
            hours,
            minutes,
            remainder,
            milliseconds
        )
    }
}
