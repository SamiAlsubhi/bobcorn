import SwiftUI
import TorrentKit

/// A feed source's movies, or its episodes under TV Shows.
struct FeedGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        let feed = model.feedBrowse
        let shows = model.section == .shows
        let titles = feed.titles.filter { ($0.episodeTag != nil) == shows }
        ScrollView {
            HStack(alignment: .firstTextBaseline) {
                Text(model.searchText.isEmpty ? model.section.title : "Results for “\(model.searchText)”")
                    .font(.system(size: 20, weight: .bold))
                if !titles.isEmpty {
                    Text("\(titles.count) titles · \(titles.reduce(0) { $0 + $1.options.count }) torrents")
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, 4)
                }
                Spacer()
                Button {
                    model.reloadBrowse(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Reload the feed")
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)

            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(titles) { title in
                    FeedCard(title: title)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Group {
                if feed.isLoading {
                    ProgressView().padding(30)
                } else if let error = feed.error {
                    VStack(spacing: 10) {
                        Text("Couldn't load \(feed.source?.name ?? "this source")").font(.headline)
                        Text(error).foregroundStyle(Theme.secondary).font(.callout).multilineTextAlignment(.center)
                        HStack {
                            Button("Try Again") { model.reloadBrowse(force: true) }.buttonStyle(AccentButtonStyle())
                            SettingsLink { Text("Edit Sources") }.buttonStyle(AccentButtonStyle(prominent: false))
                        }
                    }
                    .padding(40)
                } else if titles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: shows ? "tv" : "film.stack").font(.system(size: 34)).foregroundStyle(Theme.tertiary)
                        Text(!model.searchText.isEmpty ? "Nothing matches" : shows ? "This feed lists no episodes" : "This feed lists no movies").font(.headline)
                    }
                    .padding(60)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
    }
}

/// A poster when the feed gives one, otherwise the title set on a tinted card.
struct FeedArtwork: View {
    let imageURL: URL?
    let name: String
    let tag: String?
    let icon: String

    init(title: FeedTitle) {
        self.init(imageURL: title.imageURL, name: title.title, tag: title.episodeTag, icon: title.episodeTag == nil ? "film" : "tv")
    }

    init(imageURL: URL?, name: String, tag: String?, icon: String) {
        self.imageURL = imageURL
        self.name = name
        self.tag = tag
        self.icon = icon
    }

    var body: some View {
        if let url = imageURL {
            RemoteImage(url: url)
        } else {
            let hue = Double(abs(name.hashValue % 360)) / 360
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(hue: hue, saturation: 0.45, brightness: 0.38), Color(hue: hue, saturation: 0.55, brightness: 0.16)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(name)
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                    if let tag {
                        Text(tag).font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .padding(14)
            }
        }
    }
}

struct FeedCard: View {
    @Environment(AppModel.self) private var model
    let title: FeedTitle
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedFeedTitle = title
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { FeedArtwork(title: title) }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            ForEach(title.qualities.prefix(3), id: \.self) { q in
                                Text(q)
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.black.opacity(0.6)))
                            }
                        }
                        .padding(7)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let status = model.downloads.status(forTorrents: title.options) {
                            DownloadBadge(status: status).padding(7)
                        } else if let seeds = title.bestSeeders {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up").font(.system(size: 9, weight: .heavy))
                                Text(seeds.formatted(.number.notation(.compactName)))
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(seeds > 0 ? Color.green : Theme.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .padding(7)
                            .help("\(seeds) seeds")
                        }
                    }
                    .overlay {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.white, Theme.accent)
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(hovering ? 0.6 : 0.35), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.035 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                    Text([title.year.map(String.init), title.episodeTag, "\(title.options.count) option\(title.options.count == 1 ? "" : "s")"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// A feed title's page: what the feed says about it, and every torrent of it
/// as an option, most seeds first.
struct FeedDetailView: View {
    @Environment(AppModel.self) private var model
    let title: FeedTitle
    @State private var check = SeedCheck()
    @State private var expanded = false

    var body: some View {
        let options = check.ordered(title.options)
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                BlurredBackdrop(url: title.imageURL)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(0.5)
                    .overlay(LinearGradient(
                        colors: [Theme.background.opacity(0.35), Theme.background.opacity(0.85), Theme.background],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .clipped()
            }
            .ignoresSafeArea()
            .overlay(alignment: .top) { WindowDragArea().frame(height: 54) }

            ScrollView {
                HStack(alignment: .top, spacing: 40) {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .frame(width: 240)
                        .overlay { FeedArtwork(title: title) }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: .black.opacity(0.6), radius: 24, y: 12)

                    VStack(alignment: .leading, spacing: 16) {
                        Text(title.title)
                            .font(.system(size: 34, weight: .heavy))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 14) {
                            if let year = title.year { Text(String(year)) }
                            if let tag = title.episodeTag { Text(tag) }
                            if let category = title.options.first?.entry.category { Text(category) }
                            if let date = title.published { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                            if let source = model.feedBrowse.source { Text("from \(source.name)").foregroundStyle(Theme.tertiary) }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))

                        if let summary = title.summary.map(HTML.clean), !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .foregroundStyle(.white.opacity(0.85))
                                .lineLimit(expanded ? nil : 5)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            if summary.count > 360 {
                                Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.accent)
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }

                        if let best = options.first {
                            HStack(spacing: 12) {
                                Button {
                                    model.playFeed(best, in: title)
                                } label: {
                                    Label("Watch Now", systemImage: "play.fill")
                                }
                                .buttonStyle(AccentButtonStyle())
                                .keyboardShortcut(.defaultAction)
                                DownloadButton(status: model.downloads.status(forTorrents: title.options),
                                               ids: model.downloads.ids(forTorrents: title.options)) {
                                    model.downloadFeed(best, in: title)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(title.options.count == 1 ? "Torrent" : "Options · most seeds first")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                            VStack(spacing: 2) {
                                ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                                    OptionRow(option: option, best: i == 0, check: check, download: { model.downloadFeed(option, in: title) }) {
                                        model.playFeed(option, in: title)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 48)
                .padding(.top, 76)
                .padding(.bottom, 40)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Button {
                model.selectedFeedTitle = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.leading, 86)
            .padding(.top, 13)
        }
        .background(Theme.background)
        .onAppear { check.run(title.options) }
        .onDisappear { check.cancel() }
    }
}

struct OptionRow: View {
    @Environment(AppModel.self) private var model
    let option: FeedOption
    let best: Bool
    let check: SeedCheck
    var download: (() -> Void)?
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        let seeds = check.seeders(option)
        let leechers = check.leechers(option)
        HStack(spacing: 14) {
            Text(option.release.quality ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(option.entry.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let size = option.entry.size { Text(formatSize(size)) }
                    Text(option.entry.magnet != nil ? "magnet" : ".torrent")
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle()
                    .fill(healthColor(seeds))
                    .frame(width: 7, height: 7)
                if let seeds {
                    Text("\(seeds) \(seeds == 1 ? "seed" : "seeds")")
                    if let leechers { Text("· \(leechers) \(leechers == 1 ? "peer" : "peers")").foregroundStyle(Theme.tertiary) }
                } else if check.pending.contains(option.id) {
                    Text("checking…").foregroundStyle(Theme.tertiary)
                } else {
                    Text("seeds unknown").foregroundStyle(Theme.tertiary)
                }
            }
            .font(.system(size: 12))
            .frame(minWidth: 130, alignment: .trailing)
            if let download {
                DownloadControl(status: model.downloads.status(forTorrent: option.entry.infoHash, link: option.entry.link), download: download)
            }
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .padding(8)
                    .background(Circle().fill(best || hovering ? Theme.accent : Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.white.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .onHover { hovering = $0 }
    }

    private func healthColor(_ seeds: Int?) -> Color {
        guard let seeds else { return .gray }
        if seeds >= 10 { return .green }
        if seeds >= 1 { return Theme.gold }
        return .red
    }
}
