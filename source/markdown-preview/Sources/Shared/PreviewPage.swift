import Foundation
import WebKit

/// Builds the full HTML page shown by both the Quick Look extension and the editor window.
enum PreviewPage {
    static func html(for markdown: String, fileURL: URL?, topInset: Int = 0) -> String {
        let body = MarkdownRenderer.render(markdown, imageResolver: fileURL.map(imageResolver(relativeTo:)))
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style>
        <style>body { padding-top: \(28 + topInset)px; }</style>
        </head>
        <body><article id="content">\(body)</article></body>
        </html>
        """
    }

    /// Body fragment only, used to refresh an already loaded page without losing scroll position.
    static func bodyHTML(for markdown: String, fileURL: URL?) -> String {
        MarkdownRenderer.render(markdown, imageResolver: fileURL.map(imageResolver(relativeTo:)))
    }

    /// Relative image paths are inlined as data: URIs so they show up without granting
    /// the web content process access to the file system. Unreadable files are left alone.
    private static func imageResolver(relativeTo fileURL: URL) -> (String) -> String? {
        let directory = fileURL.deletingLastPathComponent()
        return { source in
            guard !source.contains("://"), !source.hasPrefix("data:"), !source.hasPrefix("#") else { return nil }
            let path = source.removingPercentEncoding ?? source
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
            let mime: String
            switch url.pathExtension.lowercased() {
            case "png": mime = "image/png"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "gif": mime = "image/gif"
            case "svg": mime = "image/svg+xml"
            case "webp": mime = "image/webp"
            case "heic": mime = "image/heic"
            case "bmp": mime = "image/bmp"
            case "tif", "tiff": mime = "image/tiff"
            default: return nil
            }
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    static func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // Page scripts stay off; the host can still call evaluateJavaScript for live refresh.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    /// JavaScript that swaps the article contents in place.
    static func replaceBodyScript(_ html: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [html])
        let literal = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return "document.getElementById('content').innerHTML = \(literal)[0];"
    }

    static let css = """
    :root {
      --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
      --code-bg: rgba(129,139,152,0.12); --pre-bg: #f6f8fa; --link: #0969da;
      --quote: #59636e; --row-alt: #f6f8fa; --mark: #fff8c5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #e6edf3; --muted: #9198a1; --bg: #1e1e1e; --border: #3d444d;
        --code-bg: rgba(101,108,118,0.25); --pre-bg: #262626; --link: #4493f8;
        --quote: #9198a1; --row-alt: #252525; --mark: #4d4000;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0 auto; max-width: 860px; padding: 28px 36px 48px;
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      color: var(--fg); background: var(--bg);
      -webkit-font-smoothing: antialiased; word-wrap: break-word;
    }
    h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 0.6em; line-height: 1.25; font-weight: 600; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; }
    h6 { font-size: .85em; color: var(--muted); }
    article > :first-child { margin-top: 0; }
    p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    ul, ol { padding-left: 2em; }
    li + li { margin-top: .25em; }
    li > ul, li > ol { margin: .25em 0 0; }
    ul.contains-task-list { padding-left: 1.2em; }
    li.task-list-item { list-style: none; }
    li.task-list-item input { margin: 0 .35em 0 -1.1em; vertical-align: middle; }
    blockquote { padding: 0 1em; color: var(--quote); border-left: .25em solid var(--border); }
    blockquote > :last-child { margin-bottom: 0; }
    code, pre { font: 12.5px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
    code { background: var(--code-bg); padding: .15em .4em; border-radius: 6px; }
    pre { background: var(--pre-bg); padding: 14px 16px; border-radius: 8px; overflow: auto; }
    pre code { background: none; padding: 0; border-radius: 0; white-space: pre; }
    pre.front-matter { color: var(--muted); }
    hr { height: 2px; border: 0; background: var(--border); margin: 1.6em 0; }
    table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
    th, td { border: 1px solid var(--border); padding: 6px 13px; }
    th { font-weight: 600; }
    tr:nth-child(2n) td { background: var(--row-alt); }
    img { max-width: 100%; }
    del { color: var(--muted); }
    mark { background: var(--mark); color: inherit; }
    kbd {
      font: 11px ui-monospace, Menlo, monospace; padding: 2px 5px; border: 1px solid var(--border);
      border-bottom-width: 2px; border-radius: 5px; background: var(--pre-bg);
    }
    """
}

enum TextFile {
    /// Reads a text file, preferring UTF-8 and falling back to encoding detection.
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        let data = try Data(contentsOf: url)
        return decode(data)
    }

    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        var converted: NSString?
        let raw = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        if let s = converted, raw != 0 { return (s as String, String.Encoding(rawValue: raw)) }
        return (String(decoding: data, as: UTF8.self), .utf8)
    }
}
