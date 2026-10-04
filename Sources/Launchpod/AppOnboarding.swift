import AppKit
import SwiftUI
import LaunchpodCore
import MacAppCore
import MacAppSettings
import MacAppOnboarding

@MainActor
final class AppOnboarding {
    static let version = 1
    static let completionKey = "Launchpod.onboarding.completedVersion"
    let model: OnboardingModel
    let permissions: PermissionSettingsModel
    let reporting: CrashReportingPreference?
    let agreement: TermsAgreementModel
    private let host: OnboardingWindowController
    var window: NSWindow? { host.window }
    var isVisible: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    init(identity: SettingsIdentity, permissions: PermissionSettingsModel, agreement: TermsAgreementModel,
         reporting: CrashReportingPreference?, store: OnboardingStore? = nil,
         autosaveName: String = "Launchpod.Onboarding",
         onFinish: @escaping () -> Void = {}, onDismiss: @escaping () -> Void = {},
         onQuit: @escaping () -> Void) throws {
        self.permissions = permissions
        self.agreement = agreement
        self.reporting = reporting
        var steps: [OnboardingStep] = [
            .welcome(message: L10n.text("Find your apps quickly and arrange them your way.", "앱을 빠르게 찾고 원하는 순서로 정리하세요.")),
            .guide(id: "open", title: L10n.text("Open Launchpod", "Launchpod 열기"),
                message: L10n.text("Click the Dock or menu bar icon to open Launchpod. The default keyboard shortcut is Control–Option–L. Change it in Settings → Keyboard Shortcuts.",
                    "Dock이나 메뉴바 아이콘을 클릭하면 Launchpod가 열립니다. 기본 단축키는 Control–Option–L이며, 설정 → 단축키에서 바꿀 수 있습니다."),
                illustration: .init(Image(systemName: "keyboard"), accessibilityLabel: L10n.text("Keyboard shortcut", "키보드 단축키"))),
            .guide(id: "organize", title: L10n.text("Make room for your apps", "앱을 편하게 정리하세요"),
                message: L10n.text("Type to search. Drag apps to rearrange them or create folders. Grid size and layout import are in the second Settings tab, Features. Gestures and hot corners are in Keyboard Shortcuts.",
                    "입력해서 앱을 검색하고, 드래그해서 순서를 바꾸거나 폴더를 만드세요. 격자·배치 가져오기는 설정의 두 번째 기능 탭에, 제스처·핫 코너는 단축키 탭에 있습니다."),
                illustration: .init(Self.organizingScreenshot().map { Image(nsImage: $0) } ?? Image(systemName: "square.grid.3x3.fill"),
                    accessibilityLabel: L10n.text("Launchpod showing app search, Calendar, Notes and a Utilities folder", "앱 검색창과 캘린더·메모·유틸리티 폴더가 있는 Launchpod 화면"))),
            .terms(agreement),
            .permissions(permissions)
        ]
        if let reporting {
            steps.append(.diagnostics(reporting, explanation: L10n.text(
                "If enabled, technical crash reports, including app/macOS versions and stack traces, are sent to Sentry in the United States. Changes apply after restarting. You can read the Privacy Policy in Settings → Help & Support.",
                "켜면 앱·macOS 버전과 호출 스택 등 기술적 충돌 정보가 미국의 Sentry로 전송됩니다. 변경은 앱 재실행 후 적용됩니다. 개인정보 처리방침은 설정 → 도움말 및 지원에서 읽을 수 있습니다.")))
        }
        model = try OnboardingModel(steps: steps, version: Self.version,
            store: store ?? OnboardingStore(key: Self.completionKey))
        host = OnboardingWindowController(identity: identity, model: model,
            autosaveName: autosaveName, onFinish: onFinish, onDismiss: onDismiss, onQuit: onQuit)
    }

    @discardableResult func showIfNeeded() -> Bool { host.showIfNeeded() }

    func showForReview() throws { try host.showForReview() }

    static func organizingScreenshot() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "organize.\(AppLocalizer.current.languageCode)",
                                          withExtension: "png", subdirectory: "Onboarding") else { return nil }
        return NSImage(contentsOf: url)
    }
}
