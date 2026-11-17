import SwiftUI
import WebKit

/// A YouTube video id that is safe to place in a URL or in HTML.
struct YouTubeVideoID: Hashable, Identifiable, Sendable {
    let rawValue: String

    /// Accepts only the characters YouTube ids are made of, so a value supplied by
    /// an add-on can never inject markup into the player page.
    init?(_ text: String) {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard (6 ... 20).contains(text.count), text.allSatisfy(allowed.contains) else { return nil }
        rawValue = text
    }

    var id: String { rawValue }

    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(rawValue)")
    }

    var embedURL: String {
        "https://www.youtube-nocookie.com/embed/\(rawValue)?autoplay=1&playsinline=1&rel=0"
    }
}

/// A sheet that plays a trailer in YouTube's own embedded player.
struct TrailerView: View {
    let video: YouTubeVideoID
    let title: String
    /// Identifies the app to YouTube, which requires embedders to send a referrer.
    let appIdentifier: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if let watchURL = video.watchURL {
                    Button("Open in Browser") {
                        openURL(watchURL)
                    }
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            YouTubePlayer(video: video, appIdentifier: appIdentifier)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        .frame(minWidth: 720, idealWidth: 960)
    }
}

private struct YouTubePlayer: NSViewRepresentable {
    let video: YouTubeVideoID
    let appIdentifier: String

    func makeNSView(context _: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        load(into: webView)
        return webView
    }

    func updateNSView(_: WKWebView, context _: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator _: ()) {
        // Stop playback when the sheet closes.
        webView.loadHTMLString("", baseURL: nil)
    }

    private func load(into webView: WKWebView) {
        let html = """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html, body { margin: 0; height: 100%; background: #000; } iframe { border: 0; width: 100%; height: 100%; }</style>
        </head>
        <body>
        <iframe src="\(video.embedURL)" referrerpolicy="strict-origin-when-cross-origin"
                allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://\(appIdentifier.lowercased())"))
    }
}
