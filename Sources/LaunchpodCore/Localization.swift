import Foundation

public enum AppLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    public var title: String { self == .english ? "English" : "한국어" }
}

/// App-owned language preference, independent of the macOS language.
public enum L10n {
    public static var defaults: UserDefaults = .standard
    public static let preferenceKey = "appLanguage"
    public static let didChange = Notification.Name("LaunchpodLanguageDidChange")

    public static func language(in defaults: UserDefaults) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .english
    }

    public static var language: AppLanguage { language(in: defaults) }

    public static func select(_ language: AppLanguage, defaults: UserDefaults? = nil) {
        (defaults ?? self.defaults).set(language.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func text(_ english: String, _ korean: String) -> String {
        language == .korean ? korean : english
    }
}
