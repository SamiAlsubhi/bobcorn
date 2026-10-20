import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates Bobcorn from its GitHub releases: finds a newer one, downloads its
/// installer, checks the installer was signed by the release workflow, swaps
/// the app in place and relaunches.
@MainActor
@Observable
final class Updater {
    struct Release: Equatable, Sendable {
        let version: String
        let installer: URL
        let signature: URL
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, downloading, installing
    }

    private(set) var available: Release?
    private(set) var state: State = .idle
    private var started = false

    static let repository = "SamiAlsubhi/bobcorn"
    /// Signs every release installer; its private half is the repository's
    /// UPDATE_SIGNING_KEY secret (see scripts/sign-update.swift).
    nonisolated static let publicKey = "snRDEn1DuwXMBui+4IDoWLLUkJ1h6B8oq1AlPefWEyE="

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Debug builds look for updates only where a test points them.
    private static var feed: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BOBCORN_UPDATE_FEED"].flatMap(URL.init(string:))
        #else
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        #endif
    }

    private static var key: String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BOBCORN_UPDATE_KEY"] ?? publicKey
        #else
        return publicKey
        #endif
    }

    /// Checks now and every six hours.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                _ = try? await check()
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    /// The newer release, if there is one.
    @discardableResult
    func check() async throws -> Release? {
        guard let feed = Self.feed, state == .idle else { return available }
        state = .checking
        defer { if state == .checking { state = .idle } }
        var request = URLRequest(url: feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil } // nothing released yet
        guard let release = Self.parse(data), Self.isNewer(release.version, than: Self.currentVersion) else {
            available = nil
            return nil
        }
        available = release
        return release
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let assets = (json["assets"] as? [[String: Any]] ?? []).reduce(into: [String: URL]()) { out, a in
            if let name = a["name"] as? String, let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) {
                out[name] = url
            }
        }
        guard let installer = assets["Bobcorn.dmg"], let signature = assets["Bobcorn.dmg.sig"] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, installer: installer, signature: signature, page: page)
    }

    /// "1.10.0" is newer than "1.9.2".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0
            let q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Downloads, checks and installs the release, then relaunches. Returns
    /// only if something went wrong.
    func install() async throws {
        guard let release = available, state == .idle else { return }
        state = .downloading
        defer { state = .idle }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("bobcorn-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Bobcorn.dmg")
        let (downloaded, response) = try await URLSession.shared.download(from: release.installer)
        try FileManager.default.moveItem(at: downloaded, to: dmg)
        guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 300 else { throw UpdateError.download }
        let (signature, _) = try await URLSession.shared.data(from: release.signature)
        try Self.verify(installer: dmg, signature: signature, key: Self.key)

        state = .installing
        let app = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        try await Task.detached {
            try Self.replace(app, withAppIn: dmg, bundleID: bundleID, version: release.version)
        }.value
        relaunch(app)
    }

    /// The installer must carry a signature from the release key.
    nonisolated static func verify(installer: URL, signature: Data, key: String) throws {
        guard let keyData = Data(base64Encoded: key),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              publicKey.isValidSignature(sig, for: try Data(contentsOf: installer))
        else { throw UpdateError.signature }
    }

    /// Mounts the installer, checks the app inside is this app at the new
    /// version, and swaps it in for the running one.
    nonisolated static func replace(_ app: URL, withAppIn dmg: URL, bundleID: String, version: String) throws {
        let fm = FileManager.default
        let parent = app.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }
        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mount")
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let fresh = mount.appendingPathComponent(app.lastPathComponent)
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == version
        else { throw UpdateError.wrongApp }

        // Copied beside the old app first, so the swap itself is two renames.
        let staged = parent.appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent)-\(version).app")
        let old = parent.appendingPathComponent(".\(app.deletingPathExtension().lastPathComponent)-old.app")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        try run("/usr/bin/ditto", [fresh.path, staged.path])
        try fm.moveItem(at: app, to: old)
        do {
            try fm.moveItem(at: staged, to: app)
        } catch {
            try? fm.moveItem(at: old, to: app)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool((tool as NSString).lastPathComponent) }
    }

    /// Opens the new app once this one has quit.
    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    enum UpdateError: LocalizedError {
        case download
        case signature
        case wrongApp
        case notWritable(String)
        case tool(String)

        var errorDescription: String? {
            switch self {
            case .download: return "The update didn't download."
            case .signature: return "The update isn't signed by Bobcorn's release key, so it wasn't installed."
            case .wrongApp: return "The update holds a different app than expected, so it wasn't installed."
            case .notWritable(let path): return "Bobcorn can't replace itself in \(path). Download the update from GitHub instead."
            case .tool(let name): return "Installing the update failed (\(name))."
            }
        }
    }
}
