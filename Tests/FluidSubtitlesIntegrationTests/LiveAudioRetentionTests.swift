import XCTest
@testable import FluidSubtitles_Debug

final class LiveAudioRetentionTests: XCTestCase {
    func testRingBufferDropsSamplesPastCapAndKeepsLogicalIndices() {
        let buffer = ThreadSafeAudioBuffer(maximumRetainedSamples: 8)
        buffer.append([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])

        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.logicalStart, 2)
        XCTAssertEqual(buffer.retainedCount, 8)
        XCTAssertEqual(buffer.getRetained(), [2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(buffer.getRange(startingAt: 0, count: 2), [])
        XCTAssertEqual(buffer.getRange(startingAt: 2, count: 3), [2, 3, 4])
        XCTAssertEqual(buffer.getPrefix(4), [2, 3, 4, 5])
        XCTAssertEqual(buffer.getAll(), buffer.getRetained())
    }

    func testDropSamplesBeforeAdvancesLogicalStart() {
        let buffer = ThreadSafeAudioBuffer(maximumRetainedSamples: 16)
        buffer.append(Array(0..<10).map(Float.init))
        buffer.dropSamples(before: 6)

        XCTAssertEqual(buffer.logicalStart, 6)
        XCTAssertEqual(buffer.getRetained(), [6, 7, 8, 9])
        XCTAssertEqual(buffer.getRange(startingAt: 6, count: 2), [6, 7])
        XCTAssertEqual(buffer.getRange(startingAt: 4, count: 2), [])
    }

    func testIncrementalPreviewCopiesDeltaOnly() {
        let tenMinutes = 10 * 60 * 16_000
        let retained = Array(repeating: Float(1), count: LiveAudioRetention.maximumRetainedSamples)
        let deltaStart = tenMinutes - 16_000
        let preview = StreamingTranscriptStitcher.previewChunk(
            logicalSampleCount: tenMinutes,
            logicalStart: tenMinutes - retained.count,
            incrementalDeltaStart: deltaStart,
            retained: retained
        )

        XCTAssertEqual(preview.kind, .incrementalDelta)
        XCTAssertEqual(preview.samples.count, 16_000)
        XCTAssertLessThan(preview.samples.count, tenMinutes)
    }

    func testIncrementalPreviewCanCopyDeltaFromTheRingWithoutTheFullWindow() {
        let buffer = ThreadSafeAudioBuffer(maximumRetainedSamples: 32)
        buffer.append(Array(0..<32).map(Float.init))
        let delta = buffer.getRange(startingAt: 24, count: 8)
        XCTAssertEqual(delta, Array(24..<32).map(Float.init))
        XCTAssertEqual(delta.count, 8)
        XCTAssertEqual(buffer.retainedCount, 32)
    }

    func testWindowedPreviewCopiesLastThirtySecondsNeverFullPrefix() {
        let tenMinutes = 10 * 60 * 16_000
        let retained = Array(repeating: Float(0.5), count: LiveAudioRetention.maximumRetainedSamples)
        let preview = StreamingTranscriptStitcher.previewChunk(
            logicalSampleCount: tenMinutes,
            logicalStart: tenMinutes - retained.count,
            incrementalDeltaStart: nil,
            retained: retained
        )

        XCTAssertEqual(preview.kind, .retainedWindow)
        XCTAssertEqual(preview.samples.count, LiveAudioRetention.maximumRetainedSamples)
        XCTAssertLessThan(preview.samples.count, tenMinutes)
    }

    func testLiveTranscriptBoundKeepsTheNewestSentences() {
        let older = (1...80).map { "This is committed sentence number \($0) of the talk." }.joined(separator: " ")
        let newest = "And this is the clause we are speaking now."
        let bounded = StreamingTranscriptStitcher.boundLiveTranscript(older + " " + newest)
        XCTAssertLessThanOrEqual(bounded.count, StreamingTranscriptStitcher.maximumLiveCharacters)
        XCTAssertTrue(bounded.hasSuffix(newest))
        XCTAssertFalse(bounded.contains("sentence number 1 of the talk"))
        XCTAssertEqual(StreamingTranscriptStitcher.boundLiveTranscript("Short."), "Short.")
    }

    func testWindowStitchRewritesOverlapWithoutDuplicatingSentences() {
        let committed = "Welcome everyone. Today we will cover memory."
        let incoming = "Today we will cover memory. Please silence your phones."
        let stitched = StreamingTranscriptStitcher.stitch(committed: committed, incoming: incoming)

        XCTAssertEqual(stitched, "Welcome everyone. Today we will cover memory. Please silence your phones.")
        XCTAssertEqual(stitched.components(separatedBy: "Today we will cover memory.").count - 1, 1)
    }

    func testWhisperReleaseMemoryLeavesDiskCacheUntouched() async {
        let provider = WhisperProvider()
        let existedOnDisk = provider.modelsExistOnDisk()
        await provider.releaseMemory()
        XCTAssertEqual(provider.modelsExistOnDisk(), existedOnDisk)
        XCTAssertFalse(provider.isReady)
    }

    #if arch(arm64)
    func testFluidAudioReleaseMemoryLeavesDiskCacheUntouched() async {
        let provider = FluidAudioProvider()
        let existedOnDisk = provider.modelsExistOnDisk()
        await provider.releaseMemory()
        XCTAssertEqual(provider.modelsExistOnDisk(), existedOnDisk)
        XCTAssertFalse(provider.isReady)
    }
    #endif
}
