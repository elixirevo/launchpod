import AppKit
import MacAppCore
import MacAppSettings
import MacAppOnboarding

@MainActor enum OnboardingChecks {
    static func run(outputDirectory: URL) async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "Launchpod.OnboardingChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            checks += 1
        }
        let domain = "app.launchpod.OnboardingChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(9, forKey: "columns")
        let reporting = CrashReportingPreference(defaults: defaults)
        var requests = 0, starts = 0, resumes = 0, quits = 0
        let permissions = PermissionSettingsModel([
            .init(id: "accessibility", title: AppLocalizer.current.languageCode == "ko" ? "손쉬운 사용" : "Accessibility",
                detail: AppPermissions().settings.permissions[0].detail,
                readStatus: { .notGranted }, request: { requests += 1 })
        ])
        let identity = SettingsIdentity(icon: NSImage(named: NSImage.applicationIconName))
        let receiptStore = TermsAcceptanceStore(defaults: defaults, key: AppStartup.acceptanceKey)
        let completionStore = OnboardingStore(defaults: defaults, key: AppOnboarding.completionKey)
        func make(receipt: TermsAcceptanceStore? = nil, completion: OnboardingStore? = nil,
                  report: CrashReportingPreference? = reporting) throws -> AppStartup {
            try AppStartup(identity: identity, permissions: permissions, reporting: report,
                acceptanceStore: receipt ?? receiptStore, onboardingStore: completion ?? completionStore,
                autosavePrefix: domain, startFeatures: { starts += 1 }, resumeFeatures: { resumes += 1 }, onQuit: { quits += 1 })
        }
        func settle(_ flow: AppOnboarding) async throws {
            try await Task.sleep(nanoseconds: 170_000_000)
            for _ in 0..<20 where flow.model.isBusy { try await Task.sleep(nanoseconds: 50_000_000) }
            try check(!flow.model.isBusy, "Permission status refresh completes without requesting access")
        }
        func reachTerms(_ flow: AppOnboarding) async throws {
            while flow.model.currentStep.id != "terms" {
                try await settle(flow)
                try check(!flow.model.advance(), "Guide pages never finish setup")
            }
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try check(AppOnboarding.organizingScreenshot() != nil, "Localized screenshot is bundled")
        let first = try make()
        first.begin()
        let flow = first.onboarding!
        try await settle(flow)
        try check(flow.model.steps.map(\.id) == ["welcome", "guide.open", "guide.organize", "terms", "permissions.accessibility", "diagnostics"], "Six-step setup is preserved")
        try check(flow.agreement === first.agreement && flow.permissions === permissions && flow.reporting === reporting, "Onboarding shares agreement, permission and diagnostics models")
        first.startIfAllowed()
        try check(!first.allowsAppUse && starts == 0, "Launcher, catalog, SDK and input services cannot start before agreement")
        flow.window?.performClose(nil)
        try check(quits == 1 && starts == 0 && defaults.object(forKey: AppStartup.acceptanceKey) == nil, "Closing before agreement requests quit without a receipt or feature startup")
        flow.showIfNeeded()
        try await reachTerms(flow)
        try check(!flow.model.canAdvance && !flow.model.advance() && flow.model.currentStep.id == "terms", "Unchecked terms cannot advance")
        first.agreement.isAcknowledged = true
        try check(!first.agreement.allowsAppUse && defaults.object(forKey: AppStartup.acceptanceKey) == nil, "Checkbox alone never records agreement")
        flow.window?.performClose(nil)
        flow.showIfNeeded()
        try check(!first.agreement.isAcknowledged && quits == 2, "Reopening clears an unsaved checkbox and closing remains Quit")
        first.agreement.isAcknowledged = true
        try check(!flow.model.advance() && first.agreement.allowsAppUse && starts == 0, "Explicit agreement persists before optional setup without starting services early")
        let receiptData = defaults.data(forKey: AppStartup.acceptanceKey)!
        let receipt = try JSONDecoder().decode(TermsAcceptance.self, from: receiptData)
        try check(receipt.documentID == "launchpod.terms-of-use" && receipt.version == AppStartup.termsVersion && receipt.language == AppLocalizer.current.languageCode && receipt.fullTextSHA256.count == 64, "Receipt records the displayed document version, language, hash and time")
        try await settle(flow)
        flow.window?.performClose(nil)
        try check(starts == 1 && first.allowsAppUse && defaults.integer(forKey: AppOnboarding.completionKey) == 0, "Set Up Later after agreement starts the app but leaves setup incomplete")
        first.presentIfNeeded()
        try await settle(flow)
        flow.window?.performClose(nil)
        try check(starts == 1 && resumes == 1, "Deferring reopened optional setup restores the launcher without restarting services")
        first.startIfAllowed()
        try check(starts == 1 && !reporting.selection && requests == 0 && defaults.integer(forKey: "columns") == 9, "Feature startup is idempotent and preserves separate preferences and OS permissions")
        _ = try LegalDocument.terms.text(); _ = try LegalDocument.privacy.text()
        try check(defaults.data(forKey: AppStartup.acceptanceKey) == receiptData, "Settings document reads do not create or replace agreement receipts")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var memoryReceipt: TermsAcceptance?
            var completed = 0
            let preview = try make(receipt: .init(read: { memoryReceipt }, write: { memoryReceipt = $0 }),
                completion: .init(readCompletedVersion: { completed }, writeCompletedVersion: { completed = $0 }))
            let current = preview.onboarding!
            current.window?.appearance = NSAppearance(named: appearance)
            preview.begin()
            for index in current.model.steps.indices {
                try await settle(current)
                guard let window = current.window else { throw CocoaError(.fileReadUnknown) }
                try check(window.contentLayoutRect.size == NSSize(width: 600, height: 560) && !window.styleMask.contains(.resizable), "Every page retains the package's fixed window size")
                try capture(window, to: outputDirectory.appendingPathComponent("\(AppLocalizer.current.languageCode)-\(appearance.rawValue)-\(index)-\(current.model.currentStep.id).png"))
                if current.model.currentStep.id == "terms" {
                    try check(!current.model.canAdvance, "Terms starts unchecked in both appearances")
                    preview.agreement.isAcknowledged = true
                    try await settle(current)
                    try capture(window, to: outputDirectory.appendingPathComponent("\(AppLocalizer.current.languageCode)-\(appearance.rawValue)-terms-checked.png"))
                }
                if !current.model.isLastStep { current.model.advance() }
            }
            try check(current.model.advance() && completed == AppOnboarding.version && memoryReceipt != nil, "Finish saves onboarding separately from the earlier agreement")
            current.window?.orderOut(nil)
            preview.startIfAllowed()
            try check(preview.allowsAppUse && !preview.presentIfNeeded(), "Completed and accepted setup stays closed")

            let oldDocument = try TermsDocument(id: preview.agreement.document.id, version: "1.2", language: "en", changes: "Previous release", fullText: "Previous terms")
            var oldReceipt: TermsAcceptance? = TermsAcceptance(document: oldDocument, acceptedAt: Date())
            let updated = try make(receipt: .init(read: { oldReceipt }, write: { oldReceipt = $0 }),
                completion: .init(readCompletedVersion: { AppOnboarding.version }, writeCompletedVersion: { _ in assertionFailure("Must preserve completion") }))
            let before = starts
            updated.termsWindow.window?.appearance = NSAppearance(named: appearance)
            updated.begin()
            try await settle(updated.onboarding)
            try check(!updated.allowsAppUse && starts == before && updated.termsWindow.window?.isVisible == true && updated.onboarding.window?.isVisible == false, "Changed terms use the standalone agreement window without repeating onboarding or starting services")
            try capture(updated.termsWindow.window!, to: outputDirectory.appendingPathComponent("\(AppLocalizer.current.languageCode)-\(appearance.rawValue)-updated-terms.png"))
            updated.agreement.isAcknowledged = true
            try check(updated.agreement.accept(), "Explicit updated agreement is saved")
            updated.termsWindow.window?.orderOut(nil)
            updated.startIfAllowed()
            try check(updated.allowsAppUse && oldReceipt?.version == AppStartup.termsVersion && starts == before + 1, "Updated agreement unlocks features exactly once")
        }

        defaults.set(AppOnboarding.version, forKey: AppOnboarding.completionKey)
        let returning = try make()
        returning.begin()
        try check(returning.allowsAppUse && !returning.presentIfNeeded(), "Existing completion plus current agreement skips setup")
        let startsBeforeReview = starts, resumesBeforeReview = resumes, quitsBeforeReview = quits
        let completionBeforeReview = defaults.integer(forKey: AppOnboarding.completionKey)
        let review = try returning.onboarding.model.makeReviewModel()
        try check(review.currentIndex == 0 && review.shouldPresent && !review.requiresTermsAgreement,
                  "Review begins at welcome without demanding accepted terms again")
        for _ in review.steps.indices {
            if review.currentStep.id == "terms" {
                try check(review.currentTermsAgreement === returning.agreement && review.canAdvance,
                          "Review shares the existing accepted terms model")
            }
            review.advance()
        }
        try check(!review.shouldPresent && defaults.integer(forKey: AppOnboarding.completionKey) == completionBeforeReview && defaults.data(forKey: AppStartup.acceptanceKey) == receiptData,
                  "Finishing review preserves completion and the exact agreement receipt")
        let freshReview = try returning.onboarding.model.makeReviewModel()
        try check(freshReview.currentIndex == 0, "Each new review starts from welcome")
        var reviewError: Error?
        let support = try SupportSettingsModel(diagnostics: .init(identity: identity),
            links: [try SupportLink(.contact, url: URL(string: "mailto:elixirevo@gmail.com")!)], showOnboarding: {
            do { try returning.onboarding.showForReview() } catch { reviewError = error }
        })
        try check(support.canShowOnboarding, "Support exposes the host-provided review action")
        support.showOnboarding()
        try await settle(returning.onboarding)
        func reviewWindows() -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && $0.frameAutosaveName == domain + ".Onboarding.Review" }
        }
        try check(reviewError == nil && reviewWindows().count == 1 && returning.onboarding.window?.isVisible == false,
                  "Support opens one separate review window for completed users")
        let reviewWindow = reviewWindows()[0]
        try capture(reviewWindow, to: outputDirectory.appendingPathComponent("\(AppLocalizer.current.languageCode)-review.png"))
        support.showOnboarding()
        try check(reviewWindows().count == 1 && reviewWindows()[0] === reviewWindow, "Repeated support clicks reuse the visible review window")
        reviewWindow.performClose(nil)
        try check(reviewWindows().isEmpty && starts == startsBeforeReview && resumes == resumesBeforeReview && quits == quitsBeforeReview,
                  "Closing review neither quits nor reruns initial startup or resume callbacks")
        support.showOnboarding()
        try await settle(returning.onboarding)
        try check(reviewWindows().count == 1 && reviewWindows()[0] !== reviewWindow, "Reopening after close creates a fresh review presentation")
        reviewWindows()[0].performClose(nil)
        try check(defaults.integer(forKey: AppOnboarding.completionKey) == completionBeforeReview && defaults.data(forKey: AppStartup.acceptanceKey) == receiptData && !reporting.selection && requests == 0,
                  "Review opening and closing preserve completion, agreement, reporting consent and permissions")
        let missing = try make(receipt: .init(read: { nil }, write: { _ in }))
        missing.begin()
        try check(!missing.allowsAppUse && missing.termsWindow.window?.isVisible == true, "Legacy completion without a receipt requires agreement only")
        missing.termsWindow.window?.performClose(nil)

        defaults.set(Data("invalid".utf8), forKey: AppStartup.acceptanceKey)
        let corrupt = try make()
        corrupt.startIfAllowed()
        try check(corrupt.agreement.hasReadError && !corrupt.allowsAppUse && !corrupt.agreement.canAccept, "Corrupt receipts fail closed and are not deleted")
        defaults.set(receiptData, forKey: AppStartup.acceptanceKey)
        corrupt.agreement.reload()
        corrupt.startIfAllowed()
        try check(corrupt.allowsAppUse, "A repaired store can be reloaded without inventing consent")

        var fail = true, saved: TermsAcceptance?
        let retry = try make(receipt: .init(read: { saved }, write: {
            if fail { throw CocoaError(.fileWriteNoPermission) }; saved = $0
        }), completion: .init(readCompletedVersion: { 0 }, writeCompletedVersion: { _ in }))
        try await reachTerms(retry.onboarding)
        retry.agreement.isAcknowledged = true
        try check(!retry.onboarding.model.advance() && !retry.allowsAppUse && saved == nil && retry.onboarding.model.currentStep.id == "terms", "Failed agreement writes cannot advance or unlock the app")
        fail = false
        retry.onboarding.model.advance()
        try check(saved != nil && retry.agreement.allowsAppUse, "Agreement persistence can be retried")
        let translated = try TermsDocument(id: retry.agreement.document.id, version: AppStartup.termsVersion, language: "other", changes: "Translation", fullText: "Equivalent translation")
        let translatedReceipt = TermsAcceptance(document: translated, acceptedAt: Date())
        let languageChange = try make(receipt: .init(read: { translatedReceipt }, write: { _ in assertionFailure("Must not ask twice for equivalent translations") }))
        languageChange.begin()
        try check(languageChange.allowsAppUse, "A language change preserves acceptance of the same document/version")
        let noDiagnostics = try make(report: nil)
        try check(noDiagnostics.onboarding.model.steps.count == 5, "Unconfigured diagnostics are omitted")
        try check(NSApp.activationPolicy() == .accessory && requests == 0 && !reporting.selection, "Checks preserve menu-bar policy and never request permissions or crash reporting")
        let report = "PASS: \(checks) onboarding, terms migration and startup-gating checks (\(AppLocalizer.current.languageCode))\nLight/dark screenshots captured. All agreements use isolated synthetic stores; no live permissions, telemetry or production agreement writes.\n"
        try report.write(to: outputDirectory.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    private static func capture(_ window: NSWindow, to url: URL) throws {
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
