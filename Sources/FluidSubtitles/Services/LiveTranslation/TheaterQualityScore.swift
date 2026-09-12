import Foundation

/// Printed-line quality for a stage Listen. Compact scripts use characters;
/// English uses words. This is a local score, not a published SLO.
enum TheaterQualityScore {
    /// Would I show this caption behind a speaker? 15% error or better.
    static let stageAcceptableError = 0.15

    struct Fixture: Equatable {
        let languageID: String
        let spoken: String
        let expectedUnit: String
    }

    static let english = Fixture(
        languageID: "en",
        spoken: "Today we trained the model.",
        expectedUnit: "Today we trained the model."
    )

    static let korean = Fixture(
        languageID: "ko",
        spoken: "오늘 모델을 학습했습니다",
        expectedUnit: "오늘 모델을 학습했습니다"
    )

    static let thai = Fixture(
        languageID: "th",
        spoken: "วันนี้เราฝึกโมเดลครับ",
        expectedUnit: "วันนี้เราฝึกโมเดลครับ"
    )

    static let stageLanguages: [Fixture] = [Self.english, Self.korean, Self.thai]

    struct PairFixture: Equatable {
        let sourceLanguageID: String
        let targetLanguageID: String
        let source: String
        let referenceCaption: String
    }

    static let englishToKorean = PairFixture(
        sourceLanguageID: "en",
        targetLanguageID: "ko",
        source: "Today we trained the model.",
        referenceCaption: "오늘 모델을 학습했습니다."
    )

    static let koreanToEnglish = PairFixture(
        sourceLanguageID: "ko",
        targetLanguageID: "en",
        source: "오늘 모델을 학습했습니다",
        referenceCaption: "Today we trained the model."
    )

    static let englishToThai = PairFixture(
        sourceLanguageID: "en",
        targetLanguageID: "th",
        source: "Today we trained the model.",
        referenceCaption: "วันนี้เราฝึกโมเดลครับ"
    )

    static let stagePairs: [PairFixture] = [
        Self.englishToKorean,
        Self.koreanToEnglish,
        Self.englishToThai,
    ]

    struct LineScore: Equatable {
        let languageID: String
        let reference: String
        let hypothesis: String
        let error: Double
        let wouldShow: Bool
    }

    struct TalkReport: Equatable, Codable {
        var asrError: Double?
        var translationError: Double?
        var wouldShowASR: Bool
        var wouldShowTranslation: Bool
        var lineCount: Int
        var endToEndMilliseconds: Int?
        var machineTranslationMilliseconds: Int?
    }

    static func scoreLine(reference: String, hypothesis: String, languageID: String) -> LineScore {
        let error: Double
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "th", "ja", "zh":
            error = self.characterErrorRate(reference: reference, hypothesis: hypothesis)
        default:
            error = self.wordErrorRate(reference: reference, hypothesis: hypothesis)
        }
        return LineScore(
            languageID: languageID,
            reference: reference,
            hypothesis: hypothesis,
            error: error,
            wouldShow: error <= Self.stageAcceptableError
        )
    }

    static func meanError(_ scores: [LineScore]) -> Double? {
        guard !scores.isEmpty else { return nil }
        return scores.map(\.error).reduce(0, +) / Double(scores.count)
    }

    static func report(
        asr: [(reference: String, hypothesis: String, languageID: String)],
        translations: [(reference: String, hypothesis: String, languageID: String)],
        latency: LastListenLatencyStore.Record? = nil
    ) -> TalkReport {
        let asrScores = asr.map {
            self.scoreLine(reference: $0.reference, hypothesis: $0.hypothesis, languageID: $0.languageID)
        }
        let mtScores = translations.map {
            self.scoreLine(reference: $0.reference, hypothesis: $0.hypothesis, languageID: $0.languageID)
        }
        return TalkReport(
            asrError: self.meanError(asrScores),
            translationError: self.meanError(mtScores),
            wouldShowASR: asrScores.allSatisfy(\.wouldShow),
            wouldShowTranslation: mtScores.allSatisfy(\.wouldShow),
            lineCount: max(asrScores.count, mtScores.count),
            endToEndMilliseconds: latency?.endToEndMilliseconds,
            machineTranslationMilliseconds: latency?.machineTranslationMilliseconds
        )
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        self.errorRate(
            reference: Self.tokens(reference),
            hypothesis: Self.tokens(hypothesis)
        )
    }

    static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = Array(Self.foldedLetters(reference))
        let hyp = Array(Self.foldedLetters(hypothesis))
        return self.errorRate(reference: ref, hypothesis: hyp)
    }

    static func isStageAcceptable(
        reference: String,
        hypothesis: String,
        languageID: String
    ) -> Bool {
        let error: Double
        switch TranslationClauseSegmenter.languageCode(from: languageID) {
        case "ko", "th", "ja", "zh":
            error = self.characterErrorRate(reference: reference, hypothesis: hypothesis)
        default:
            error = self.wordErrorRate(reference: reference, hypothesis: hypothesis)
        }
        return error <= Self.stageAcceptableError
    }

    private static func errorRate<T: Equatable>(reference: [T], hypothesis: [T]) -> Double {
        if reference.isEmpty {
            return hypothesis.isEmpty ? 0 : 1
        }
        return Double(self.editDistance(reference, hypothesis)) / Double(reference.count)
    }

    private static func tokens(_ text: String) -> [String] {
        text
            .lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func foldedLetters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func editDistance<T: Equatable>(_ left: [T], _ right: [T]) -> Int {
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for (i, leftItem) in left.enumerated() {
            current[0] = i + 1
            for (j, rightItem) in right.enumerated() {
                let cost = leftItem == rightItem ? 0 : 1
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
