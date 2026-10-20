import AppKit
import CoreImage
import SwiftUI

/// Posters, cached in memory and on disk.
actor ImageLoader {
    static let shared = ImageLoader()

    private let memory = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bobcorn/Images", isDirectory: true)
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 400 << 20, directory: dir)
        c.requestCachePolicy = .returnCacheDataElseLoad
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    init() {
        memory.countLimit = 600
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let running = inflight[url] { return await running.value }
        let task = Task<NSImage?, Never> { [session] in
            guard let (data, _) = try? await session.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// A poster blurred once with Core Image, for backdrops. Cheaper than a live
/// blur filter on a full-window layer.
struct BlurredBackdrop: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .task(id: url) {
            guard let url, let source = await ImageLoader.shared.image(for: url) else { return }
            let blurred = await Task.detached(priority: .utility) { Self.blur(source) }.value
            withAnimation(.easeOut(duration: 0.3)) { image = blurred }
        }
    }

    nonisolated private static func blur(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        // Downscale first: a blur this heavy loses nothing at 1/4 size.
        let scaled = input.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let output = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: 6)
            .cropped(to: scaled.extent)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: result.width, height: result.height))
    }
}

struct RemoteImage: View {
    let url: URL?
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Theme.card, Theme.card.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                Image(systemName: failed ? "film" : "popcorn")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .task(id: url) {
            guard let url else { return }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }
}

enum Theme {
    static let background = Color(red: 0.086, green: 0.086, blue: 0.106)
    static let bar = Color(red: 0.118, green: 0.118, blue: 0.141)
    static let card = Color(red: 0.165, green: 0.165, blue: 0.192)
    static let accent = Color(red: 0.937, green: 0.282, blue: 0.231)
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.25)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
}

struct RatingStars: View {
    let rating: Double
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                let fill = rating - Double(i)
                Image(systemName: fill >= 0.75 ? "star.fill" : fill >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(Theme.gold)
            }
        }
    }
}

struct AccentButtonStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? Theme.accent : Color.white.opacity(0.1))
            )
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// Lets the window be dragged from the custom title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let s = Int(seconds)
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatRate(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// External players that can take an HTTP stream of formats AVPlayer cannot play.
enum ExternalPlayer: String, CaseIterable, Identifiable {
    case iina = "com.colliderli.iina"
    case vlc = "org.videolan.vlc"
    case infuse = "com.firecore.infuse"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .iina: return "IINA"
        case .vlc: return "VLC"
        case .infuse: return "Infuse"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

    static var installed: [ExternalPlayer] { allCases.filter { $0.appURL != nil } }

    func open(_ url: URL) {
        guard let app = appURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
