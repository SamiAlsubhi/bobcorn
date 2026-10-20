import SwiftUI

/// Subtitles for what's playing, from OpenSubtitles: picking one downloads it
/// and shows it.
struct SubtitleSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: PlaybackController
    @State private var language = OpenSubtitles.preferredLanguage
    @State private var phase = Phase.matching
    @State private var results: [OpenSubtitles.Subtitle] = []
    @State private var attempt = 0
    @State private var downloading: Int?
    @State private var downloadError: String?

    private enum Phase: Equatable {
        case matching, searching, done
        case failed(OpenSubtitles.Failure)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subtitles from OpenSubtitles")
                        .font(.system(size: 16, weight: .bold))
                    Text(controller.displaySubtitle.map { "\($0) · \(controller.displayTitle)" } ?? controller.displayTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Picker("Language", selection: $language) {
                    ForEach(OpenSubtitles.languages, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            .padding(20)

            Divider()

            content
                .frame(height: 340)

            Divider()

            HStack(alignment: .firstTextBaseline) {
                if let downloadError {
                    Text(downloadError).foregroundStyle(.orange)
                } else {
                    Text("Picking a subtitle downloads it. A free key downloads 5 a day; one you've downloaded before is free.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 11))
            .padding(16)
        }
        .frame(width: 640)
        .task(id: "\(language)#\(attempt)") { await search() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .matching, .searching:
            VStack(spacing: 10) {
                ProgressView()
                Text(phase == .matching ? "Matching this video's file…" : "Searching OpenSubtitles…")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let failure):
            VStack(spacing: 12) {
                Image(systemName: failure == .noKey ? "key" : "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.gold)
                Text(failure.localizedDescription)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                HStack {
                    if failure.isAboutTheKey {
                        SettingsLink { Text("Open Settings…") }
                        Link("Get a Key", destination: OpenSubtitles.keyPage)
                    }
                    Button("Try Again") { attempt += 1 }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done where results.isEmpty:
            Text("No \(OpenSubtitles.languageName(language)) subtitles found.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            List(results) { subtitle in
                row(subtitle)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ subtitle: OpenSubtitles.Subtitle) -> some View {
        Button { download(subtitle) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtitle.release.isEmpty ? "Untitled" : subtitle.release)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if subtitle.matchesFile { tag("Matches this file", "checkmark.seal.fill", .green) }
                        if subtitle.isOnDisk { tag("Downloaded", "arrow.down.circle.fill", .secondary) }
                        if subtitle.hearingImpaired { tag("Hearing impaired", "ear", .secondary) }
                        if subtitle.machineTranslated { tag("Machine translated", "cpu", .orange) }
                    }
                }
                Spacer()
                if downloading == subtitle.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label(subtitle.downloads.formatted(), systemImage: "arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Downloads on OpenSubtitles")
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
    }

    private func tag(_ text: String, _ symbol: String, _ color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private func search() async {
        UserDefaults.standard.set(language, forKey: Pref.subtitleLanguage)
        results = []
        guard var query = controller.subtitleSearch else { return }
        guard !OpenSubtitles.apiKey.isEmpty else {
            phase = .failed(.noKey)
            return
        }
        phase = .matching
        query.hash = await controller.fileHash(within: 8)
        query.language = language
        guard !Task.isCancelled else { return }
        phase = .searching
        do {
            let found = try await OpenSubtitles.search(query)
            guard !Task.isCancelled else { return }
            results = OpenSubtitles.ranked(found, fileName: query.fileName)
            phase = .done
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error as? OpenSubtitles.Failure ?? .other(error.localizedDescription))
        }
    }

    private func download(_ subtitle: OpenSubtitles.Subtitle) {
        downloading = subtitle.id
        downloadError = nil
        Task {
            do {
                let (url, remaining) = try await OpenSubtitles.file(for: subtitle)
                controller.useDownloadedSubtitle(subtitle, at: url)
                if let remaining {
                    controller.show("\(remaining) subtitle download\(remaining == 1 ? "" : "s") left today")
                }
                dismiss()
            } catch {
                downloadError = error.localizedDescription
            }
            downloading = nil
        }
    }
}
