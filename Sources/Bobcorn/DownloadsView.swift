import AppKit
import SwiftUI
import TorrentKit

// MARK: - Progress

/// A download's progress as a ring, or a tick once it's all here.
struct DownloadRing: View {
    let status: Downloads.Status
    var size: CGFloat = 16

    var body: some View {
        Group {
            if status.state == .complete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.green)
            } else {
                ZStack {
                    Circle().stroke(.white.opacity(0.22), lineWidth: max(2, size / 7))
                    Circle()
                        .trim(from: 0, to: max(0.03, status.fraction))
                        .stroke(status.state == .downloading ? Theme.accent : Theme.secondary,
                                style: StrokeStyle(lineWidth: max(2, size / 7), lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: status.state == .paused ? "pause.fill" : "arrow.down")
                        .font(.system(size: size * 0.42, weight: .heavy))
                }
                .frame(width: size, height: size)
            }
        }
        .help(status.summary)
    }
}

extension Downloads.Status {
    var percent: String { "\(Int((fraction * 100).rounded(.down)))%" }

    var summary: String {
        switch state {
        case .complete: return "Downloaded"
        case .paused: return "Paused at \(percent)"
        case .queued: return "Waiting to download (\(percent))"
        case .gettingFiles: return "Getting the file list"
        case .downloading, .streamed: return "Downloading: \(percent)"
        }
    }
}

/// On a poster: how much of the title is downloaded, or a tick.
struct DownloadBadge: View {
    let status: Downloads.Status

    var body: some View {
        HStack(spacing: 4) {
            DownloadRing(status: status, size: 12)
            if status.state != .complete { Text(status.percent) }
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.black.opacity(0.65)))
    }
}

/// In a torrent or episode row: a button to download it, or its progress.
struct DownloadControl: View {
    let status: Downloads.Status?
    let download: () -> Void

    var body: some View {
        if let status {
            DownloadRing(status: status, size: 22)
                .frame(width: 27, height: 27)
        } else {
            Button(action: download) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Download")
        }
    }
}

/// On a title's page: Download, or how it's going. Pauses and resumes it,
/// and once it's all here opens the Downloads tab.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let status: Downloads.Status?
    let ids: [String]
    var label = "Download"
    let download: () -> Void

    var body: some View {
        Button(action: act) {
            Label {
                Text(title)
            } icon: {
                if let status { DownloadRing(status: status, size: 14) } else { Image(systemName: "arrow.down.circle") }
            }
        }
        .buttonStyle(AccentButtonStyle(prominent: false))
        .help(help)
    }

    private var title: String {
        guard let status else { return label }
        switch status.state {
        case .complete: return "Downloaded"
        case .paused: return "Paused · \(status.percent)"
        case .queued: return "Waiting · \(status.percent)"
        case .gettingFiles, .downloading, .streamed: return "Downloading · \(status.percent)"
        }
    }

    private var help: String {
        switch status?.state {
        case nil: return "Download to watch without streaming"
        case .complete: return "Show in Downloads"
        case .paused: return "Resume"
        default: return "Pause"
        }
    }

    private func act() {
        switch status?.state {
        case nil, .streamed: download()
        case .complete: model.showDownloads()
        case .paused: ids.forEach(model.downloads.resume)
        default: ids.forEach(model.downloads.pause)
        }
    }
}

// MARK: - The tab

/// Everything in the cache folder: what's downloading, what's all here, and
/// what's partly here from being streamed. A show's episodes are one entry,
/// however many torrents they came in.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var deleting: [Downloads.Item] = []

    var body: some View {
        let groups = model.downloads.groups
        let active = groups.filter { [.downloading, .gettingFiles, .queued, .paused].contains($0.state) }.sorted { $0.added < $1.added }
        let done = groups.filter { $0.state == .complete }.sorted { $0.modified > $1.modified }
        let streamed = groups.filter { $0.state == .streamed && $0.bytesOnDisk > 0 }.sorted { $0.modified > $1.modified }
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Downloads").font(.system(size: 20, weight: .bold))
                    Text(formatSize(groups.reduce(0) { $0 + $1.bytesOnDisk }) + " on disk")
                        .foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button {
                        try? FileManager.default.createDirectory(at: AppModel.cacheDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([AppModel.cacheDirectory])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Show the cache folder")
                }
                .font(.system(size: 13))

                if active.isEmpty && done.isEmpty && streamed.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundStyle(Theme.tertiary)
                        Text("Nothing downloaded yet").font(.headline)
                        Text("Download a movie, an episode or a whole season from its page to watch it without streaming. What you stream shows up here too.")
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
                section("Downloading", active)
                section("Downloaded", done)
                section("Streamed", streamed,
                        note: "Parts of these are on this Mac from watching them. Clearing the cache removes them; downloads stay.")
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.downloads.refresh() }
        .confirmationDialog(deletePrompt, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                for item in deleting { model.downloads.delete(item.id) }
            }
        } message: {
            Text("Its \(formatSize(deleting.reduce(0) { $0 + max($1.bytesOnDisk, $1.bytesDone) })) on disk are removed.")
        }
    }

    private var deletePrompt: String {
        guard let first = deleting.first else { return "Delete?" }
        if deleting.count == 1, first.parts.count == 1, let part = first.parts.first, part.label != first.about.title {
            return "Delete \(part.label)?"
        }
        return "Delete \(first.about.series ?? first.about.title)?"
    }

    @ViewBuilder
    private func section(_ heading: String, _ groups: [Downloads.Group], note: String? = nil) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(heading).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.secondary)
                if let note {
                    Text(note).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                }
                VStack(spacing: 2) {
                    ForEach(groups) { group in
                        DownloadRow(group: group) { deleting = $0 }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
            }
        }
    }
}

/// A film, or a show with each of its episodes: how far along each is, and
/// what can be done with them.
private struct DownloadRow: View {
    @Environment(AppModel.self) private var model
    let group: Downloads.Group
    let delete: ([Downloads.Item]) -> Void

    var body: some View {
        let entries = group.entries
        HStack(alignment: .top, spacing: 16) {
            Button {
                if let saved = group.about.saved { model.selectedAPITitle = APITitle(saved: saved) }
            } label: {
                Color.clear
                    .frame(width: 60, height: 90)
                    .overlay { FeedArtwork(imageURL: group.about.poster, name: group.title, tag: nil, icon: group.isShow ? "tv" : "film") }
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(group.about.saved == nil)
            .help(group.about.saved == nil ? "" : "Open its page")

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        // A lone episode says which.
                        if entries.count == 1, let label = entries.first?.part.label, label != group.title {
                            Text(label)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                        Text(statusLine(entries))
                            .font(.system(size: 12))
                            .foregroundStyle(group.error == nil ? Theme.tertiary : .orange)
                            .lineLimit(1)
                    }
                    Spacer()
                    actions(entries)
                }
                if group.state != .complete {
                    ProgressView(value: group.fraction)
                        .tint(group.state == .downloading ? Theme.accent : Theme.secondary)
                }
                if entries.count > 1 {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func statusLine(_ entries: [Downloads.Group.Entry]) -> String {
        if let error = group.error { return error }
        let size = group.size
        let amount = size > 0 ? "\(formatSize(group.bytesDone)) of \(formatSize(size))" : formatSize(group.bytesOnDisk)
        let episodes = entries.count > 1 ? "\(entries.filter { $0.fraction >= 1 }.count) of \(entries.count) episodes" : nil
        let line: [String?]
        switch group.state {
        case .complete:
            let allHere = entries.allSatisfy { $0.fraction >= 1 }
            line = [allHere ? (entries.count > 1 ? "\(entries.count) episodes" : nil) : episodes, formatSize(group.bytesDone)]
        case .gettingFiles:
            line = ["Getting the file list from peers…"]
        case .downloading:
            line = [episodes, amount, group.rate.map(formatRate), group.peers.map { "\($0) peers" }]
        case .queued:
            line = ["Waiting", episodes, amount]
        case .paused:
            line = ["Paused", episodes, amount]
        case .streamed:
            line = ["\(Int(group.fraction * 100))% here", amount]
        }
        return line.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ entries: [Downloads.Group.Entry]) -> some View {
        let wanted = group.items.filter { $0.about.kept && !$0.isComplete }
        HStack(spacing: 8) {
            if entries.count == 1, let entry = entries.first {
                Button { model.playDownload(group, entry: entry) } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle(prominent: group.state == .complete))
            }
            if wanted.contains(where: { !$0.about.paused }) {
                iconButton("pause.fill", "Pause") { wanted.forEach { model.downloads.pause($0.id) } }
            } else if !wanted.isEmpty {
                iconButton("arrow.down", "Resume") { wanted.forEach { model.downloads.resume($0.id) } }
            }
            if group.state == .streamed {
                Button { group.items.forEach { model.downloads.keep($0.id) } } label: {
                    Label("Download the Rest", systemImage: "arrow.down.circle")
                }
                .buttonStyle(AccentButtonStyle(prominent: false))
            }
            iconButton("trash", "Delete") { delete(group.items) }
        }
    }

    /// An episode: its progress, Play, and the rest in its menu.
    private func entryRow(_ entry: Downloads.Group.Entry) -> some View {
        HStack(spacing: 12) {
            Text(entry.part.label)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            if entry.status.state == .complete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("\(Int(entry.fraction * 100))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                DownloadRing(status: entry.status, size: 14)
            }
            Button { model.playDownload(group, entry: entry) } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .padding(7)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .disabled(entry.part.file == nil)
            .help("Play")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            let item = entry.item
            Button("Play") { model.playDownload(group, entry: entry) }.disabled(entry.part.file == nil)
            switch item.state {
            case .downloading, .gettingFiles, .queued: Button("Pause") { model.downloads.pause(item.id) }
            case .paused: Button("Resume") { model.downloads.resume(item.id) }
            case .streamed: Button("Download the Rest") { model.downloads.keep(item.id) }
            case .complete: EmptyView()
            }
            Divider()
            // An episode in a season pack shares one torrent with the others.
            Button(item.parts.count > 1 ? "Delete the Torrent (\(item.parts.count) Episodes)…" : "Delete…") { delete([item]) }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
