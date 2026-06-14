import AppKit
import Foundation

/// ADR-0011 — minimal localization layer for the swiftc/bash build (no Xcode,
/// no SwiftGen). Symbolic keys with the English string baked in at the call
/// site as `value:`, so a missing/partial `.lproj` degrades to English instead
/// of showing a raw key.

/// Localized string with an English fallback. Reads from `AppLanguage.bundle`,
/// which is swapped live when the user changes language (no relaunch).
func NSL(_ key: String, _ english: String) -> String {
    AppLanguage.bundle.localizedString(forKey: key, value: english, table: nil)
}

/// Localized format string + args. Translations should use **positional**
/// specifiers (`%1$@`, `%2$d`) wherever argument order may differ by language.
func NSLf(_ key: String, _ english: String, _ args: CVarArg...) -> String {
    let fmt = AppLanguage.bundle.localizedString(forKey: key, value: english, table: nil)
    return String(format: fmt, locale: .current, arguments: args)
}

/// Language override + relaunch (ADR-0011 §C). We keep our own `LanguageOverride`
/// key to distinguish "user explicitly chose X" from "follow the system" — the
/// effective `AppleLanguages` array is also populated by macOS from system
/// preferences, so it can't tell those apart on its own.
enum AppLanguage {
    struct Option { let code: String; let nativeName: String }

    /// Display order in the Language popup. Only languages we actually ship —
    /// no "System Default" entry (an unsupported system language has no sane
    /// meaning there; we fall back to English instead). The popup always shows
    /// the concrete language currently in effect.
    static var options: [Option] {
        [
            Option(code: "en",      nativeName: "English"),
            Option(code: "ko",      nativeName: "한국어"),
            Option(code: "ja",      nativeName: "日本語"),
            Option(code: "zh-Hans", nativeName: "简体中文"),
            Option(code: "es",      nativeName: "Español"),
        ]
    }

    private static let overrideKey = "LanguageOverride"
    private static let appleLanguagesKey = "AppleLanguages"

    /// The bundle `NSL`/`NSLf` read from. Swapped live when the language changes
    /// so the UI re-localizes without an app relaunch (ADR-0011 §C v2).
    static var bundle: Bundle = .main

    /// Point `bundle` at the effective language's `.lproj`. Call once at launch,
    /// before any UI (and thus any `NSL`) is built.
    static func applyAtStartup() {
        bundle = lprojBundle(for: effectiveCode) ?? .main
    }

    private static func lprojBundle(for code: String) -> Bundle? {
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// The user's explicit choice, or nil when none has been made yet.
    static var currentOverride: String? {
        UserDefaults.standard.string(forKey: overrideKey)
    }

    /// The language actually in effect: the override if set, otherwise whatever
    /// macOS resolved for our bundle from the system preference — clamped to a
    /// language we ship (English when the system language isn't one of ours).
    static var effectiveCode: String {
        if let o = currentOverride, options.contains(where: { $0.code == o }) { return o }
        let resolved = Bundle.main.preferredLocalizations.first ?? "en"
        return options.contains { $0.code == resolved } ? resolved : "en"
    }

    /// Index into `options` for the language currently in effect.
    static var currentIndex: Int {
        options.firstIndex { $0.code == effectiveCode } ?? 0
    }

    /// Pin a concrete language. Swaps `bundle` immediately for a live re-localize
    /// AND persists (`AppleLanguages`) so a future cold launch keeps the choice.
    /// Caller is responsible for re-rendering visible UI (see AppDelegate.relocalize).
    static func setOverride(_ code: String) {
        UserDefaults.standard.set(code, forKey: overrideKey)
        UserDefaults.standard.set([code], forKey: appleLanguagesKey)
        bundle = lprojBundle(for: code) ?? .main
    }
}
