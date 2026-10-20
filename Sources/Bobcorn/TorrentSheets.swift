import AppKit
import SwiftUI
import TorrentKit

/// Paste a magnet link, or pick a .torrent file.
struct MagnetPrompt: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open a Torrent").font(.system(size: 18, weight: .bold))
            Text("Paste a magnet link. Bobcorn streams the video while it downloads.")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField("magnet:?xt=urn:btih:…", text: $text, axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(open)
            HStack {
                Button("Choose .torrent File…") {
                    dismiss()
                    DispatchQueue.main.async { model.openTorrentFilePanel() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("magnet:"))
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), clip.hasPrefix("magnet:") { text = clip }
        }
    }

    private func open() {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.lowercased().hasPrefix("magnet:") else { return }
        dismiss()
        DispatchQueue.main.async { model.openMagnet(link) }
    }
}

/// A torrent being opened: shows the swarm while metadata arrives, then the
/// files to pick from.
struct TorrentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let flow: TorrentFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(flow.info?.name ?? flow.name)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Group {
                if let error = flow.error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(Theme.gold)
                        Text(error).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if flow.info == nil {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Fetching the file list from peers…").font(.system(size: 13, weight: .medium))
                        Text("\(flow.stats.connectedPeers) connected · \(flow.stats.knownPeers) found")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    fileList
                }
            }
            .frame(height: 300)

            Divider()

            HStack {
                if flow.info != nil && flow.videoFiles.isEmpty {
                    Text("This torrent has no video files.").foregroundStyle(.secondary).font(.system(size: 12))
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    flow.cancel()
                    model.torrentFlow = nil
                }
                .keyboardShortcut(.cancelAction)
                if let first = flow.videoFiles.first {
                    Button("Play Best Seeded") { model.playTorrent(flow: flow, file: first) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 600)
        .interactiveDismissDisabled()
    }

    private var subtitle: String {
        if let info = flow.info {
            return "\(info.contentFiles.count) files · \(formatSize(info.totalLength))"
        }
        return "Info-hash \(flow.session.infoHashHex.prefix(12))…"
    }

    private var fileList: some View {
        List {
            if !flow.videoFiles.isEmpty {
                Section("Videos · most seeds first") {
                    ForEach(flow.videoFiles) { file in
                        HStack(spacing: 10) {
                            Image(systemName: file.playsInApp ? "film" : "film.stack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1).truncationMode(.middle)
                                Text(file.path.count > 1 ? file.path.dropLast().joined(separator: "/") : file.fileExtension.uppercased())
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let a = flow.availability[file.index] {
                                SeedLabel(availability: a)
                            }
                            Text(formatSize(file.length)).foregroundStyle(.secondary).font(.system(size: 12))
                                .frame(width: 70, alignment: .trailing)
                            Button(file.playsInApp ? "Play" : "Stream") {
                                model.playTorrent(flow: flow, file: file)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            if !flow.otherFiles.isEmpty {
                Section("Other files") {
                    ForEach(flow.otherFiles.prefix(200)) { file in
                        HStack {
                            Image(systemName: file.isSubtitle ? "captions.bubble" : "doc")
                                .foregroundStyle(.secondary)
                            Text(file.displayPath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatSize(file.length)).foregroundStyle(.secondary).font(.system(size: 12))
                        }
                    }
                }
            }
        }
    }
}

private struct SeedLabel: View {
    let availability: FileAvailability

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(availability.seeds >= 3 ? Color.green : availability.seeds > 0 ? Theme.gold : (availability.peers > 0 ? .orange : .red))
                .frame(width: 7, height: 7)
            Text(availability.seedText)
            if availability.peers > 0 {
                Text("· \(availability.peers) \(availability.peers == 1 ? "peer" : "peers")")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
}
