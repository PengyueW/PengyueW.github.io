import SwiftUI

/// The UserDefaults key that stores the user's chosen interface language. An
/// empty string means "follow the system". Shared by the App (which applies it
/// as the environment locale) and the settings picker (which writes it).
let languageDefaultsKey = "ContinuumLanguage"

/// One selectable interface language. `code` is empty for "System Default";
/// otherwise it's the BCP-47 / .lproj identifier shipped in
/// `Resources/Localizations`, kept in lock-step with `CFBundleLocalizations`.
struct AppLanguage: Identifiable, Hashable {
    let code: String          // "" = system default
    let nativeName: String    // shown in the picker, in the language itself
    var id: String { code }

    /// The locale to apply for this choice. For "System Default" we fall back
    /// to the process locale so SwiftUI resolves against the user's OS setting.
    var locale: Locale {
        code.isEmpty ? Locale.current : Locale(identifier: code)
    }

    /// Order mirrors `CFBundleLocalizations` in `Resources/Info.plist`. Each
    /// `code` must have a matching `<code>.lproj/Localizable.strings`.
    static let all: [AppLanguage] = [
        .init(code: "",        nativeName: "System Default"),
        .init(code: "en",      nativeName: "English"),
        .init(code: "es",      nativeName: "Español"),
        .init(code: "fr",      nativeName: "Français"),
        .init(code: "de",      nativeName: "Deutsch"),
        .init(code: "it",      nativeName: "Italiano"),
        .init(code: "pt-BR",   nativeName: "Português (Brasil)"),
        .init(code: "nl",      nativeName: "Nederlands"),
        .init(code: "ru",      nativeName: "Русский"),
        .init(code: "ja",      nativeName: "日本語"),
        .init(code: "ko",      nativeName: "한국어"),
        .init(code: "zh-Hans", nativeName: "简体中文"),
        .init(code: "zh-Hant", nativeName: "繁體中文"),
    ]

    /// The locale to feed into the environment for the saved code, or `nil`
    /// when the user wants the system default (so we don't override it).
    static func environmentLocale(for code: String) -> Locale? {
        code.isEmpty ? nil : Locale(identifier: code)
    }
}

/// Settings ▸ Language. Writing the picker selection to `@AppStorage` updates
/// the app's environment locale live (see `ContinuumApp`), so the whole UI
/// re-localizes immediately — no relaunch needed.
struct LanguageSettingsView: View {
    // `@AppStorage` is macOS 11; this store writes the same UserDefaults key,
    // so the value is shared with the `@AppStorage` the app scene reads.
    @ObservedObject private var store = CompatDefaultsString(key: languageDefaultsKey)

    var body: some View {
        Form {
            CompatSection("Interface Language") {
                Picker("Language", selection: $store.value) {
                    ForEach(AppLanguage.all) { lang in
                        Text(lang.nativeName).tag(lang.code)
                    }
                }
                .compatMenuPicker()
                Text("Choose the language Continuum uses for its interface. Changes apply immediately.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .compatGroupedForm()
        .frame(width: 540)
    }
}
