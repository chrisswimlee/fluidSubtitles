import XCTest
@testable import FluidSubtitles_Debug

final class LiveTranslationMailboxTests: XCTestCase {
    func testMailboxIsReadyAfterAHostStartsListening() async {
        let mailbox = TranslationRequestMailbox()
        XCTAssertFalse(mailbox.isReady)
        let serve = Task {
            _ = await mailbox.next()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(mailbox.isReady)
        mailbox.cancelAll(TranslationEngineError(message: "done"))
        serve.cancel()
        XCTAssertFalse(mailbox.isReady)
    }

    func testPackCacheKeyUsesCatalogIDs() {
        XCTAssertEqual(
            AppleTranslationEngine.packCacheKey(
                source: TranslationLanguageCatalog.english,
                target: TranslationLanguageCatalog.korean
            ),
            "en->ko"
        )
        for language in TranslationLanguageCatalog.all {
            XCTAssertFalse(language.localeLanguage.minimalIdentifier.isEmpty)
            // Norwegian is the sole exception: voice engines use "no", Apple Translation uses "nb".
            if language.id == TranslationLanguageCatalog.norwegian.id {
                XCTAssertEqual(language.appleLanguageCode, "nb")
            } else {
                XCTAssertEqual(language.appleLanguageCode, language.id)
            }
        }
    }

    @MainActor
    func testWarmMailboxIsPreferredOverAPerClauseInstall() {
        XCTAssertEqual(
            AppleTranslationEngine.sessionChoice(mailboxReady: true),
            .warmMailbox
        )
        if #available(macOS 26.0, *) {
            XCTAssertEqual(
                AppleTranslationEngine.sessionChoice(mailboxReady: false),
                .installedSessionFallback
            )
        } else {
            XCTAssertEqual(
                AppleTranslationEngine.sessionChoice(mailboxReady: false),
                .warmMailbox
            )
        }
    }

    func testSubmitThrowsWhenNoHostIsReady() async {
        let mailbox = TranslationRequestMailbox()
        do {
            _ = try await mailbox.submit("Hello")
            XCTFail("Expected not-ready error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not ready"))
        }
    }

    func testSubmitResumesWhenAHostIsListening() async throws {
        let mailbox = TranslationRequestMailbox()
        let serve = Task {
            if let request = await mailbox.next() {
                request.resume(.success("안녕"))
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let translated = try await mailbox.submit("Hello")
        XCTAssertEqual(translated, "안녕")
        serve.cancel()
    }

    func testCancelAllResumesPendingWaiters() async {
        let mailbox = TranslationRequestMailbox()
        let serve = Task {
            if let request = await mailbox.next() {
                try? await Task.sleep(nanoseconds: 200_000_000)
                request.resume(.success("too late"))
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task {
            try await mailbox.submit("Hello")
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        mailbox.cancelAll(TranslationEngineError(message: "Language pair changed."))
        do {
            _ = try await waiter.value
            XCTFail("Expected cancel to resume the waiter")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Language pair changed"))
        }
        serve.cancel()
    }

    func testLiveSubmitReplacesAQueuedLiveRequest() async throws {
        let mailbox = TranslationRequestMailbox()
        let seen = RequestLog()
        let serve = Task {
            while let request = await mailbox.next() {
                seen.append(request.text)
                try? await Task.sleep(nanoseconds: 80_000_000)
                request.resume(.success("t-\(request.text)"))
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let first = Task {
            try await mailbox.submit("Hello", kind: .live)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task {
            try await mailbox.submit("Hello world", kind: .live)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let latest = try await mailbox.submit("Hello world today", kind: .live)
        XCTAssertEqual(latest, "t-Hello world today")
        do {
            _ = try await second.value
            XCTFail("Expected the queued live request to be superseded")
        } catch {
            XCTAssertTrue((error as? TranslationEngineError)?.isSuperseded == true)
        }
        _ = try? await first.value
        XCTAssertEqual(seen.last, "Hello world today")
        XCTAssertLessThanOrEqual(seen.count, 2)
        mailbox.cancelAll(TranslationEngineError(message: "done"))
        serve.cancel()
    }

    func testCommitIsNotDroppedByALaterLiveSubmit() async throws {
        let mailbox = TranslationRequestMailbox()
        let seen = RequestLog()
        let serve = Task {
            while let request = await mailbox.next() {
                seen.append(request.text)
                try? await Task.sleep(nanoseconds: 80_000_000)
                request.resume(.success("t-\(request.text)"))
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let firstCommit = Task {
            try await mailbox.submit("First commit", kind: .commit)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let queuedCommit = Task {
            try await mailbox.submit("Second commit", kind: .commit)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let live = try await mailbox.submit("Live draft", kind: .live)
        let firstCommitted = try await firstCommit.value
        let secondCommitted = try await queuedCommit.value

        XCTAssertEqual(firstCommitted, "t-First commit")
        XCTAssertEqual(secondCommitted, "t-Second commit")
        XCTAssertEqual(live, "t-Live draft")
        XCTAssertTrue(seen.contains("First commit"))
        XCTAssertTrue(seen.contains("Second commit"))
        XCTAssertTrue(seen.contains("Live draft"))
        XCTAssertEqual(seen.values, ["First commit", "Second commit", "Live draft"])

        mailbox.cancelAll(TranslationEngineError(message: "done"))
        serve.cancel()
    }

    func testSecondServeClaimsTheMailboxWithoutLeakingAWaiter() async {
        let mailbox = TranslationRequestMailbox()
        let first = Task {
            await mailbox.next()
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(mailbox.isReady)
        let generation = mailbox.claimServe()
        let firstRequest = await first.value
        XCTAssertNil(firstRequest)
        let second = Task {
            await mailbox.next(generation: generation)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(mailbox.isReady)
        mailbox.cancelAll(TranslationEngineError(message: "done"))
        let secondRequest = await second.value
        XCTAssertNil(secondRequest)
        XCTAssertFalse(mailbox.isReady)
    }

    func testStaleGenerationDoesNotTakeANewWaiter() async {
        let mailbox = TranslationRequestMailbox()
        let oldGeneration = mailbox.claimServe()
        _ = mailbox.claimServe()
        let stale = await mailbox.next(generation: oldGeneration)
        XCTAssertNil(stale)
        mailbox.cancelAll(TranslationEngineError(message: "done"))
    }

    func testLiveDoesNotPreemptAQueuedCommit() async throws {
        let mailbox = TranslationRequestMailbox()
        let seen = RequestLog()
        let serve = Task {
            while let request = await mailbox.next() {
                seen.append(request.text)
                try? await Task.sleep(nanoseconds: 40_000_000)
                request.resume(.success("t-\(request.text)"))
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let commit = Task {
            try await mailbox.submit("Commit clause", kind: .commit)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let pendingCommit = mailbox.hasQueuedOrInFlightCommit
        XCTAssertTrue(pendingCommit)
        let live = Task {
            try await mailbox.submit("Live draft", kind: .live)
        }
        let committed = try await commit.value
        let liveCaption = try await live.value
        XCTAssertEqual(committed, "t-Commit clause")
        XCTAssertEqual(liveCaption, "t-Live draft")
        XCTAssertEqual(seen.values, ["Commit clause", "Live draft"])
        mailbox.cancelAll(TranslationEngineError(message: "done"))
        serve.cancel()
    }

    func testCancelQueuedFailsPendingSubmitWithoutKillingTheServeLoop() async {
        let mailbox = TranslationRequestMailbox()
        let serve = Task {
            if let first = await mailbox.next() {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if !first.isCancelled {
                    first.resume(.success("held"))
                }
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let first = Task {
            try await mailbox.submit("First clause", kind: .commit)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let second = Task {
            try await mailbox.submit("Queued clause", kind: .commit)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        mailbox.cancelQueued(TranslationEngineError.superseded)
        XCTAssertFalse(mailbox.hasQueuedOrInFlightCommit)
        do {
            _ = try await second.value
            XCTFail("queued submit should fail")
        } catch {
            XCTAssertTrue((error as? TranslationEngineError)?.isSuperseded == true)
        }
        _ = try? await first.value
        XCTAssertTrue(mailbox.isReady)
        mailbox.cancelAll(TranslationEngineError(message: "done"))
        serve.cancel()
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        self.lock.lock()
        self.stored.append(value)
        self.lock.unlock()
    }

    var last: String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored.last
    }

    var count: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored.count
    }

    func contains(_ value: String) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored.contains(value)
    }

    var values: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }
}
