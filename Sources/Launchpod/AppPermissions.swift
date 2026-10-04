import AppKit
import LaunchpodCore
import MacAppSettings

@MainActor
final class AppPermissions {
    let settings: PermissionSettingsModel

    init(settings: PermissionSettingsModel? = nil) {
        self.settings = settings ?? PermissionSettingsModel([
            .accessibility(detail: L10n.text("Allows trackpad gestures to open and close Launchpod. App search and launching work without this permission.",
                "트랙패드 제스처로 Launchpod를 열고 닫을 때 사용합니다. 앱 검색과 실행에는 이 권한이 필요하지 않습니다."))
        ])
    }

    /// Safe preview: shares the real wording, but never opens or changes OS permissions.
    static func preview() -> AppPermissions {
        let description = AppPermissions().settings.permissions[0]
        return AppPermissions(settings: PermissionSettingsModel([
            SettingsPermission(id: description.id, title: description.title, detail: description.detail,
                readStatus: { .notGranted }, request: {}, openSystemSettings: {})
        ]))
    }
}
