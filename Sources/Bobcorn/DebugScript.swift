#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import TorrentKit

/// Debug builds only: drives the UI from a script so a change can be checked
/// without anyone at the keyboard, writing window snapshots and player state.
///
///   BOBCORN_DEBUG_SCRIPT="wait:4;shot:grid;apidetail:0;wait:4;shot:detail;apiplay;wait:25;state;shot:player;quit"
///   BOBCORN_DEBUG_OUT=/tmp/bobcorn-shots
///
/// Steps: wait:<s>  shot:<name>  section:<movies|shows|myList>  search:<text>
/// back  magnet:<uri>  torrentfile:<path>  playlargest  seek:<seconds>  state
/// lanurl:<host>  subtitlesearch  settingsshot:<name>  close  quit
/// Sources: addsource:<name>|<feed>[|<search>]  addapi:<name>|<base url>
/// clearsources  feeddetail:<index>  feedplay  apisort:<sort>
/// apidetail:<index>  apiplay[:<episode index>]
@MainActor
enum DebugScript {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let script = env["BOBCORN_DEBUG_SCRIPT"] else { return }
        let out = URL(fileURLWithPath: env["BOBCORN_DEBUG_OUT"] ?? NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor in
            for step in steps {
                let (cmd, arg) = split(step)
                log("step \(step)")
                await run(cmd, arg, out: out)
            }
        }
    }

    private static func split(_ step: String) -> (String, String) {
        guard let i = step.firstIndex(of: ":") else { return (step, "") }
        return (String(step[..<i]), String(step[step.index(after: i)...]))
    }

    private static func log(_ s: String) {
        print("[debug] \(s)")
        fflush(stdout)
    }

    private static func run(_ cmd: String, _ arg: String, out: URL) async {
        let model = AppModel.shared
        switch cmd {
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 1) * 1_000_000_000))
        case "shot":
            snapshot(to: out.appendingPathComponent("\(arg).png"))
        case "section":
            if let s = CatalogSection(rawValue: arg) { model.section = s }
        case "search":
            model.searchText = arg
        case "back":
            model.selectedFeedTitle = nil
            model.selectedAPITitle = nil
        case "magnet":
            model.openMagnet(arg)
        case "addsource":
            // addsource:<name>|<feed url>[|<search url>]
            let parts = arg.components(separatedBy: "|")
            guard parts.count >= 2 else { return log("addsource needs name|url") }
            model.sources.upsert(CustomSource(name: parts[0], feedURL: parts[1], searchURL: parts.count > 2 ? parts[2] : ""))
            model.sourcesChanged()
        case "addapi":
            let parts = arg.components(separatedBy: "|")
            guard parts.count == 2 else { return log("addapi needs name|url") }
            model.sources.upsert(CustomSource(kind: .api, name: parts[0], feedURL: parts[1]))
            model.sourcesChanged()
        case "apisort":
            if let s = APISort(rawValue: arg) { model.apiSort = s }
        case "apidetail":
            let i = Int(arg) ?? 0
            if model.apiBrowse.titles.indices.contains(i) { model.selectedAPITitle = model.apiBrowse.titles[i] }
        case "apiplay":
            // A movie plays its best torrent; a show its nth episode with torrents.
            guard let t = model.selectedAPITitle, let base = model.apiBrowse.query?.base else { return log("no api title selected") }
            do {
                let d = try await APIClient.details(base, t)
                if t.type == .movies {
                    guard let best = d.title.options.best() else { return log("no torrents") }
                    log("apiplay \(best.qualityLabel) \(best.entry.title)")
                    model.playAPI(d, episode: nil, option: best)
                } else {
                    let playable = d.episodes.filter { !$0.options.isEmpty }
                    let i = Int(arg) ?? 0
                    guard playable.indices.contains(i), let best = playable[i].options.best() else { return log("no episode \(i)") }
                    log("apiplay \(playable[i].tag) \(best.qualityLabel) \(best.entry.title) of \(playable.count) episodes")
                    model.playAPI(d, episode: playable[i], option: best)
                }
            } catch {
                log("details failed: \(error)")
            }
        case "addsheet":
            // addsheet:<name>|<base url>: the Add Source form, filled in.
            let parts = arg.components(separatedBy: "|")
            model.addSourceDraft = CustomSource(kind: .api, name: parts.first ?? "", feedURL: parts.count > 1 ? parts[1] : "")
            model.addSourceVisible = true
        case "closesheet":
            model.addSourceVisible = false
            model.addSourceDraft = CustomSource(kind: .api, name: "", feedURL: "")
        case "clearsources":
            for s in model.sources.sources { model.sources.remove(s.id) }
            model.sourcesChanged()
        case "feeddetail":
            let i = Int(arg) ?? 0
            if model.feedBrowse.titles.indices.contains(i) { model.selectedFeedTitle = model.feedBrowse.titles[i] }
        case "feedplay":
            guard let t = model.selectedFeedTitle else { return log("no feed title selected") }
            let best = t.options.max { ($0.entry.seeders ?? -1) < ($1.entry.seeders ?? -1) } ?? t.options[0]
            log("feedplay \(best.entry.title)")
            model.playFeed(best, in: t)
        case "torrentfile":
            model.open(url: URL(fileURLWithPath: arg))
        case "playlargest":
            if let flow = model.torrentFlow, let f = flow.videoFiles.first { model.playTorrent(flow: flow, file: f) }
        case "state":
            if let pb = model.playback {
                let t = pb.player?.currentTime().seconds ?? -1
                let status = pb.player?.timeControlStatus.rawValue ?? -1
                let s = pb.stats
                log("phase=\(pb.phase) status=\(pb.statusText) started=\(pb.hasStarted) time=\(String(format: "%.1f", t)) tc=\(status) torrent=\(pb.viaTorrent) url=\(pb.streamURL?.absoluteString ?? "-")")
                if let s {
                    log("  rate=\(formatRate(s.downloadRate)) peers=\(s.connectedPeers) webseeds=\(s.activeWebSeeds) pieces=\(s.piecesHave)/\(s.piecesTotal) buffered=\(formatSize(s.bufferedAhead)) fail=\(s.hashFailures)")
                }
                if let e = pb.player?.currentItem?.error { log("  item error: \(e)") }
                if let notice = pb.notice { log("  notice: \(notice)") }
                if let remux = pb.remuxSummary { log("  remuxed: \(remux)") }
                log("  paused=\(pb.isPaused) at \(Int(pb.currentTime))s of \(Int(pb.duration))s, buffered ahead \(pb.bufferedAhead.map { "\(Int($0))s" } ?? "-"), downloaded \(pb.downloaded.map { String(format: "%.0f–%.0f%%", $0.lowerBound * 100, $0.upperBound * 100) }.joined(separator: ", ")), file \(Int((pb.stats?.selectedProgress ?? 0) * 100))%")
                if let reason = pb.externalReason { log("  external: \(reason)") }
                if let device = pb.castDevice { log("  casting to \(device.name): \(pb.castStatus.map { "\($0.state) at \(Int($0.currentTime))s of \($0.duration.map { String(Int($0)) } ?? "?")" } ?? "-")") }
                if let notice = pb.notice, pb.castDevice == nil { log("  last notice: \(notice)") }
            } else if let flow = model.torrentFlow {
                log("flow info=\(flow.info?.name ?? "nil") peers=\(flow.stats.connectedPeers) error=\(flow.error ?? "-")")
                for f in flow.videoFiles {
                    log("  \(f.name) \(formatSize(f.length)) \(flow.availability[f.index]?.seedText ?? "?")")
                }
            } else if model.section == .myList {
                log("my list saved=\(model.library.saved.map(\.title)) continue=\(model.library.continueWatching.map(\.progress.title))")
            } else if model.currentSource?.kind == .api {
                let b = model.apiBrowse
                log("api source=\(b.source?.name ?? "-") type=\(model.apiType.rawValue) sort=\(model.apiSort.rawValue) titles=\(b.titles.count) loading=\(b.isLoading) exhausted=\(b.exhausted) error=\(b.error ?? "-") detail=\(model.selectedAPITitle?.title ?? "-")")
                for t in b.titles.prefix(6) {
                    log("  \(t.id) \(t.title) [\(t.year.map(String.init) ?? "-")] rating=\(t.rating.map { String(Int($0)) } ?? "-") seasons=\(t.seasonCount.map(String.init) ?? "-") options=\(t.options.map { "\($0.qualityLabel)/\($0.entry.seeders.map(String.init) ?? "?")s/\($0.entry.size.map(formatSize) ?? "?")" }.joined(separator: ", ")) poster=\(t.posterURL != nil)")
                }
            } else if model.currentSource != nil {
                let f = model.feedBrowse
                log("feed source=\(f.source?.name ?? "-") titles=\(f.titles.count) entries=\(f.entryCount) loading=\(f.isLoading) error=\(f.error ?? "-") detail=\(model.selectedFeedTitle?.displayTitle ?? "-")")
                for t in f.titles.prefix(6) {
                    log("  \(t.displayTitle) [\(t.year.map(String.init) ?? "-")] options=\(t.options.map { "\($0.qualityLabel)/\($0.entry.seeders.map(String.init) ?? "?")s/\($0.entry.magnet != nil ? "mag" : "tor")" }.joined(separator: ", ")) img=\(t.imageURL != nil)")
                }
            } else {
                log("no source")
            }
        case "update":
            // Checks the test feed (BOBCORN_UPDATE_FEED) and installs what it offers.
            do {
                let release = try await model.updater.check()
                log("update offered=\(release?.version ?? "none") current=\(Updater.currentVersion)")
                if release != nil { try await model.updater.install() }
            } catch {
                log("update failed: \(error.localizedDescription)")
            }
        case "cachefolder":
            // cachefolder:<path>, or cachefolder: for the default.
            let moved = await model.moveCache(to: arg.isEmpty ? nil : URL(fileURLWithPath: arg, isDirectory: true))
            log("cache moved=\(moved) now \(AppModel.cacheDirectory.path)")
        case "tomatoes":
            // Sample scores, rotten to fresh, on the grid's first titles.
            for (i, t) in model.apiBrowse.titles.prefix(14).enumerated() { model.ratings.debugSet(t.id, [96, 42, 73, 12, 88, 58, 61][i % 7]) }
        case "lanurl":
            // lanurl:<host>: the playing stream's address for another device.
            guard let url = model.playback?.streamURL else { return log("nothing playing") }
            _ = try? await model.engine.server.startLAN()
            log("lan \(model.engine.server.lanURL(for: url, host: arg)?.absoluteString ?? "-")")
        case "cast":
            // Casts what's playing to the first Chromecast found.
            model.castDevices.start()
            for _ in 0..<20 where model.castDevices.devices.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard let device = model.castDevices.devices.first, let pb = model.playback else { return log("no device or nothing playing") }
            log("casting to \(device.name)")
            pb.startCasting(to: device)
        case "pause":
            model.playback?.player?.pause()
        case "resume":
            model.playback?.player?.play()
        case "seek":
            _ = await model.playback?.player?.seek(to: CMTime(seconds: Double(arg) ?? 0, preferredTimescale: 600))
        case "subtitlesearch":
            model.playback?.subtitleSearchVisible = true
        case "settingsshot":
            // Settings → Sources in a window of its own: the Settings scene
            // only opens from a menu or a SettingsLink.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SourcesSettings().environment(model).frame(width: 560, height: 430))
            window.center()
            window.orderFront(nil)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let url = out.appendingPathComponent("\(arg).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try? p.run()
            p.waitUntilExit()
            log("wrote \(url.path)")
            window.close()
        case "close":
            model.closePlayback()
        case "quit":
            NSApp.terminate(nil)
        default:
            log("unknown step \(cmd)")
        }
    }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 }) else {
            return log("no window to snapshot")
        }
        // A real screenshot of this app's own windows only (needs Screen
        // Recording permission; it shows video frames). An attached sheet is
        // its own window and gets its own file. Drawing the view hierarchy is
        // the fallback.
        func capture(_ w: NSWindow, _ out: URL) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", String(w.windowNumber), out.path]
            guard (try? p.run()) != nil else { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path)
        }
        if capture(window, url) {
            log("wrote \(url.path)")
            // Sheets and panels are windows of their own.
            let others = NSApp.windows.filter { $0 !== window && $0.isVisible && $0.frame.height > 100 }
            for (i, other) in others.enumerated() {
                let otherURL = url.deletingPathExtension().appendingPathExtension(i == 0 ? "sheet.png" : "sheet\(i + 1).png")
                if capture(other, otherURL) { log("wrote \(otherURL.path)") }
            }
            return
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return log("no window to snapshot") }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            log("wrote \(url.path)")
        }
    }
}
#endif
