import AppKit
import MacAppCore
import MacAppSettings
import MacAppOnboarding
import LaunchpodCore

/// Owns the single agreement shared by first-run setup and subsequent terms updates.
@MainActor final class AppStartup {
    static let termsVersion = "1.3"
    static let acceptanceKey = "Launchpod.terms.acceptance"
    let agreement: TermsAgreementModel
    private(set) var onboarding: AppOnboarding!
    private(set) var termsWindow: TermsAgreementWindowController!
    private(set) var hasStarted = false
    private let startFeatures: () -> Void
    private let resumeFeatures: () -> Void
    var allowsAppUse: Bool { hasStarted && agreement.allowsAppUse }

    init(identity: SettingsIdentity, permissions: PermissionSettingsModel,
         reporting: CrashReportingPreference?, acceptanceStore: TermsAcceptanceStore? = nil,
         onboardingStore: OnboardingStore? = nil, autosavePrefix: String = "Launchpod",
         startFeatures: @escaping () -> Void, resumeFeatures: @escaping () -> Void = {}, onQuit: (() -> Void)? = nil) throws {
        let quit = onQuit ?? { NSApp.terminate(nil) }
        self.startFeatures = startFeatures
        self.resumeFeatures = resumeFeatures
        let document = try TermsDocument(id: "launchpod.terms-of-use", version: Self.termsVersion,
            language: AppLocalizer.current.languageCode,
            changes: L10n.text(
                "These terms describe the free app, local data, permissions, optional crash reports, updates and your rights. This version adds explicit agreement before app use. Only the document version, displayed language, text hash and acceptance time are saved on this Mac. Crash reporting remains a separate choice.",
                "무료 앱의 이용 조건, 로컬 데이터, 권한, 선택적 충돌 보고, 업데이트와 이용자의 권리를 안내합니다. 이번 버전부터 앱 사용 전에 명시적으로 동의합니다. 문서 버전·표시 언어·전문 해시·동의 시각은 이 Mac에만 저장하며, 충돌 보고는 별도로 선택합니다."),
            fullText: LegalDocument.terms.plainText())
        agreement = TermsAgreementModel(document: document,
            store: acceptanceStore ?? TermsAcceptanceStore(key: Self.acceptanceKey))
        onboarding = try AppOnboarding(identity: identity, permissions: permissions, agreement: agreement,
            reporting: reporting, store: onboardingStore, autosaveName: autosavePrefix + ".Onboarding",
            onFinish: { [weak self] in self?.startIfAllowed() },
            onDismiss: { [weak self] in self?.startIfAllowed() }, onQuit: quit)
        termsWindow = TermsAgreementWindowController(identity: identity, model: agreement,
            autosaveName: autosavePrefix + ".Terms",
            onAccepted: { [weak self] in self?.startIfAllowed() }, onQuit: quit)
    }

    func begin() { if !presentIfNeeded() { startIfAllowed() } }

    /// An existing completion record never becomes an agreement receipt.
    @discardableResult func presentIfNeeded() -> Bool {
        if onboarding.model.completedVersion < AppOnboarding.version { return onboarding.showIfNeeded() }
        return termsWindow.showIfNeeded()
    }

    func startIfAllowed() {
        guard agreement.allowsAppUse else { return }
        if hasStarted { resumeFeatures(); return }
        hasStarted = true
        startFeatures()
    }
}
