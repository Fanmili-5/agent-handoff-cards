import Foundation

enum WorkbenchLanguage: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"

    private static let bundles: [Self: Bundle] = Dictionary(uniqueKeysWithValues: allCases.map { language in
        let directory = Bundle.main.resourceURL?.appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
        return (language, directory.flatMap { Bundle(url: $0) } ?? .main)
    })

    static var preferred: Self {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }

    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let localization = Self.bundles[self] ?? .main
        let format = localization.localizedString(forKey: key, value: nil, table: nil)
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}
