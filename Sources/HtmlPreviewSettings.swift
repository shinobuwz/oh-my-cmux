import Foundation

/// How `.html` / `.htm` files are opened from interactive entrypoints
/// (terminal Cmd-click, file-tree activation, app `openURLs`).
///
/// `browser` routes the file to a built-in cmux browser surface, rendering the
/// page — including its inline/external JavaScript — inside the embedded
/// WKWebView. `text` preserves the historical behavior of opening the file in
/// the plain-text `FilePreviewPanel`, which is sandbox-safe (no script
/// execution) at the cost of showing the source.
///
/// The default is `browser`: opening an HTML file in a browser matches the
/// user's mental model of "open this file" for a web document. Users who prefer
/// source view (e.g. inspecting markup) can set `files.htmlPreview = "text"`
/// in `~/.config/cmux/cmux.json` or the Settings window.
enum HtmlPreviewMode: String, CaseIterable, Sendable {
    /// Open in the built-in cmux browser surface (default).
    case browser
    /// Open in the plain-text file preview editor (no script execution).
    case text
}

enum HtmlPreviewSettings {
    /// UserDefaults / cmux.json key (`files.htmlPreview`).
    static let key = "files.htmlPreview"

    static let didChangeNotification = Notification.Name("cmux.htmlPreviewSettingsDidChange")

    /// Default mode: render HTML files in the embedded browser.
    static let defaultMode: HtmlPreviewMode = .browser

    /// Parse a raw config/UserDefaults string into a mode, falling back to
    /// ``defaultMode`` for `nil` or unrecognized values.
    static func mode(forRawValue raw: String?) -> HtmlPreviewMode {
        guard let raw, let mode = HtmlPreviewMode(rawValue: raw) else {
            return defaultMode
        }
        return mode
    }

    static func resolvedMode(defaults: UserDefaults = .standard) -> HtmlPreviewMode {
        mode(forRawValue: defaults.string(forKey: key))
    }

    static func setMode(
        _ mode: HtmlPreviewMode,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        defaults.set(mode.rawValue, forKey: key)
        notificationCenter.post(name: didChangeNotification, object: nil)
    }
}
