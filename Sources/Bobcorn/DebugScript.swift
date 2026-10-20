#if DEBUG
import AppKit
import AVFoundation
import TorrentKit

/// Debug builds only: drives the UI from a script so a change can be checked
/// without anyone at the keyboard, writing window snapshots and player state.
///
///   BOBCORN_DEBUG_SCRIPT="wait:6;shot:grid;detail:0;wait:4;shot:detail;play;wait:25;state;shot:player;quit"
///   BOBCORN_DEBUG_OUT=/tmp/bobcorn-shots
///
/// Steps: wait:<s>  shot:<name>  section:<movies|shows|animation|sources|myList>
/// search:<text>  detail:<index>  back  play  magnet:<uri>  torrentfile:<path>
/// playlargest  seek:<seconds>  state  close  quit
/// Sources: addsource:<name>|<feed>[|<search>]  addapi:<name>|<base url>
/// clearsources  feeddetail:<index>  feedplay  apitype:<movies|shows>
/// apisort:<sort>  apidetail:<index>  apiplay[:<episode index>]
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
        case "detail":
            let i = Int(arg) ?? 0
            if model.browse.items.indices.contains(i) { model.selectedItem = model.browse.items[i] }
        case "back":
            model.selectedItem = nil
            model.selectedFeedTitle = nil
            model.selectedAPITitle = nil
        case "play":
            guard let item = model.selectedItem else { return log("no item selected") }
            do {
                let d = try await ArchiveClient.details(for: item)
                guard let g = d.videos.first(where: { $0.preferred(dataSaver: false)?.isNative == true }) ?? d.videos.first else {
                    return log("no videos")
                }
                log("playing \(g.title) [\(g.preferred(dataSaver: false)?.name ?? "?")] torrent=\(d.hasTorrent) servers=\(d.servers)")
                model.play(details: d, group: g, variant: nil)
            } catch {
                log("details failed: \(error)")
            }
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
        case "apitype":
            if let t = APIMediaType(rawValue: arg) { model.apiType = t }
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
        case "probe":
            if let p = SwarmProbe.latest {
                for (name, a) in p.byFile.sorted(by: { $0.key < $1.key }) {
                    log("  \(name): \(a.seedText), \(a.peers) partial peers")
                }
            } else {
                log("no probe")
            }
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
                if let reason = pb.externalReason { log("  external: \(reason)") }
            } else if let flow = model.torrentFlow {
                log("flow info=\(flow.info?.name ?? "nil") peers=\(flow.stats.connectedPeers) error=\(flow.error ?? "-")")
                for f in flow.videoFiles {
                    log("  \(f.name) \(formatSize(f.length)) \(flow.availability[f.index]?.seedText ?? "?")")
                }
            } else if model.section == .sources, model.currentSource?.kind == .api {
                let b = model.apiBrowse
                log("api source=\(b.source?.name ?? "-") type=\(model.apiType.rawValue) sort=\(model.apiSort.rawValue) titles=\(b.titles.count) loading=\(b.isLoading) exhausted=\(b.exhausted) error=\(b.error ?? "-") detail=\(model.selectedAPITitle?.title ?? "-")")
                for t in b.titles.prefix(6) {
                    log("  \(t.id) \(t.title) [\(t.year.map(String.init) ?? "-")] rating=\(t.rating.map { String(Int($0)) } ?? "-") seasons=\(t.seasonCount.map(String.init) ?? "-") options=\(t.options.map { "\($0.qualityLabel)/\($0.entry.seeders.map(String.init) ?? "?")s/\($0.entry.size.map(formatSize) ?? "?")" }.joined(separator: ", ")) poster=\(t.posterURL != nil)")
                }
            } else if model.section == .sources {
                let f = model.feedBrowse
                log("feed source=\(f.source?.name ?? "-") titles=\(f.titles.count) entries=\(f.entryCount) loading=\(f.isLoading) error=\(f.error ?? "-") detail=\(model.selectedFeedTitle?.displayTitle ?? "-")")
                for t in f.titles.prefix(6) {
                    log("  \(t.displayTitle) [\(t.year.map(String.init) ?? "-")] options=\(t.options.map { "\($0.qualityLabel)/\($0.entry.seeders.map(String.init) ?? "?")s/\($0.entry.magnet != nil ? "mag" : "tor")" }.joined(separator: ", ")) img=\(t.imageURL != nil)")
                }
            } else {
                log("browse items=\(model.browse.items.count) total=\(model.browse.total) error=\(model.browse.error ?? "-") detail=\(model.selectedItem?.id ?? "-")")
            }
        case "seek":
            _ = await model.playback?.player?.seek(to: CMTime(seconds: Double(arg) ?? 0, preferredTimescale: 600))
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
            if let sheet = window.attachedSheet {
                let sheetURL = url.deletingPathExtension().appendingPathExtension("sheet.png")
                if capture(sheet, sheetURL) { log("wrote \(sheetURL.path)") }
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
