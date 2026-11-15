import SwiftUI
import UIKit

/// In-memory cache for thumbnails so lists don't refetch on scroll.
enum ImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}

/// Loads an image through the authenticated client (AsyncImage can't send headers).
struct AuthImage: View {
    @Environment(AppModel.self) private var model
    let url: URL
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipped()
        .task(id: url) {
            if let cached = ImageCache.shared.object(forKey: url as NSURL) {
                image = cached
                return
            }
            guard let client = model.client else { return }
            do {
                let data = try await client.image(at: url)
                if let img = UIImage(data: data) {
                    ImageCache.shared.setObject(img, forKey: url as NSURL)
                    image = img
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}

/// Periodically refreshed still frame from `/api/<camera>/latest.jpg`.
/// Used for the camera grid and as the low-bandwidth live mode.
struct SnapshotView: View {
    @Environment(AppModel.self) private var model
    let camera: Camera
    var height: Int = 360
    var interval: Duration = .seconds(5)
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if let errorText {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                    Text(errorText).font(.caption2).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            } else {
                ProgressView().tint(.white)
            }
        }
        .clipped()
        .task(id: camera.name) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            let data = try await client.latestFrame(camera: camera.name, height: height)
            if let img = UIImage(data: data) {
                image = img
                errorText = nil
            }
        } catch is CancellationError {
        } catch {
            if image == nil { errorText = error.localizedDescription }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center).font(.callout)
            if let retry { Button("Try again", action: retry).buttonStyle(.bordered) }
        }
        .padding()
    }
}

extension Date {
    init(unix: Double) { self.init(timeIntervalSince1970: unix) }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()

    static let shortTime: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
