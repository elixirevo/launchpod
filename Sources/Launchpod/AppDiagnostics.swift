import Foundation
import LaunchpodCore
import MacAppCore
import MacAppDiagnosticsSentry

@MainActor
final class AppDiagnostics {
    let preference: CrashReportingPreference
    private(set) var service: SentryDiagnostics?
    private(set) var error: String?
    private let isolated: Bool

    init(isolated: Bool = false) {
        self.isolated = isolated
        preference = isolated ? CrashReportingPreference(activeEnabled: false, save: { _ in }) : CrashReportingPreference()
    }

    /// Load public configuration without starting SDKs before required terms are accepted.
    func prepare() {
        guard service == nil else { return }
        do {
            guard let configuration = try SentryDiagnosticsConfiguration.bundled(in: .module, appBundle: .main) else { return }
            let candidate = SentryDiagnostics(configuration: configuration)
            service = candidate
        } catch {
            self.error = L10n.text("Crash reporting is unavailable in this build. Please contact support.",
                                   "이 빌드에서는 충돌 보고를 사용할 수 없습니다. 지원팀에 문의해 주세요.")
            NSLog("Launchpod: crash reporting configuration/startup failed")
        }
    }

    func start() {
        prepare()
        guard !isolated else { return }
        do { try service?.startIfConsented(preference) }
        catch {
            self.error = L10n.text("Crash reporting is unavailable in this build. Please contact support.",
                              "이 빌드에서는 충돌 보고를 사용할 수 없습니다. 지원팀에 문의해 주세요.")
            service = nil
        }
    }
}
