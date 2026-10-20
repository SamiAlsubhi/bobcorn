import SwiftUI
import TorrentKit

/// The Sources tab for a catalog API: its movies or shows, a page at a time.
struct APIGrid: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        let browse = model.apiBrowse
        ScrollView {
            HStack(alignment: .center, spacing: 18) {
                Text(heading)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer()
                Menu {
                    Picker("Genre", selection: $model.apiGenre) {
                        ForEach(APIQuery.genres) { g in Text(g.name).tag(g) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterLabel(title: "Genre", value: model.apiGenre.name)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Menu {
                    Picker("Sort by", selection: $model.apiSort) {
                        ForEach(APISort.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterLabel(title: "Sort by", value: model.apiSort.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                Picker("Show", selection: $model.apiType) {
                    ForEach(APIMediaType.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    model.reloadBrowse()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Reload")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 28)
            .padding(.top, 22)

            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(browse.titles) { title in
                    APICard(title: title)
                        .onAppear {
                            if let i = browse.titles.firstIndex(of: title), i >= browse.titles.count - 18 { browse.loadMore() }
                        }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Group {
                if browse.isLoading {
                    ProgressView().padding(30)
                } else if let error = browse.error {
                    VStack(spacing: 10) {
                        Text("Couldn't load \(browse.source?.name ?? "this source")").font(.headline)
                        Text(error).foregroundStyle(Theme.secondary).font(.callout).multilineTextAlignment(.center)
                        HStack {
                            Button("Try Again") { browse.retry() }.buttonStyle(AccentButtonStyle())
                            SettingsLink { Text("Edit Sources") }.buttonStyle(AccentButtonStyle(prominent: false))
                        }
                    }
                    .padding(40)
                } else if browse.titles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: model.apiType == .movies ? "film.stack" : "tv").font(.system(size: 34)).foregroundStyle(Theme.tertiary)
                        Text("Nothing found").font(.headline)
                        Text("Try another genre or search.").foregroundStyle(Theme.secondary)
                    }
                    .padding(60)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
    }

    private var heading: String {
        if !model.searchText.isEmpty { return "Results for “\(model.searchText)”" }
        if model.apiGenre != .all { return model.apiGenre.name }
        return model.apiBrowse.source?.name ?? "Sources"
    }
}

struct APICard: View {
    @Environment(AppModel.self) private var model
    let title: APITitle
    @State private var hovering = false

    var body: some View {
        let watched = model.library.isWatched(title.libraryKey)
        let seeds = title.options.compactMap(\.entry.seeders).max()
        Button {
            model.selectedAPITitle = title
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { APIArtwork(title: title) }
                    .overlay {
                        ZStack {
                            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            VStack(spacing: 10) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white, Theme.accent)
                                if let stars = title.stars, let rating = title.rating {
                                    VStack(spacing: 3) {
                                        RatingStars(rating: stars)
                                        Text("\(Int(rating.rounded()))%")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                }
                            }
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            if watched {
                                Image(systemName: "eye.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(.black.opacity(0.6)))
                                    .help("Watched")
                            }
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
                        if let seeds {
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
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(hovering ? 0.6 : 0.35), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.035 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .contextMenu {
            if title.type == .movies {
                Button(watched ? "Mark as Unwatched" : "Mark as Watched") { model.library.setWatched(title.libraryKey, !watched) }
            }
            if let url = title.imdbURL {
                Button("Open on IMDb") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var subtitle: String {
        var parts = [title.year.map(String.init)]
        if let n = title.seasonCount, n > 0 { parts.append(n == 1 ? "1 season" : "\(n) seasons") }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? " " : text
    }
}

/// The poster, or the title set on a tinted card when the API has none.
struct APIArtwork: View {
    let title: APITitle

    var body: some View {
        FeedArtwork(imageURL: title.posterURL, name: title.title, tag: nil, icon: title.type == .movies ? "film" : "tv")
    }
}

/// A catalog API title's page. A movie lists its torrents, most seeds first;
/// a show lists its seasons, and each episode its torrents.
struct APIDetailView: View {
    @Environment(AppModel.self) private var model
    let title: APITitle

    @State private var details: APIDetails?
    @State private var error: String?
    @State private var season: Int?
    @State private var openEpisodeID: String?
    @State private var expanded = false
    @State private var check = SeedCheck()

    private var shown: APITitle { details?.title ?? title }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                BlurredBackdrop(url: shown.fanartURL ?? shown.posterURL)
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
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if let details, title.type == .shows, !details.episodes.isEmpty {
                        episodes(details)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 76)
                .padding(.bottom, 40)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Button {
                model.selectedAPITitle = nil
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
        .task(id: title.id) { await load() }
        .onDisappear { check.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 260)
                .overlay { APIArtwork(title: shown) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 16) {
                Text(shown.title)
                    .font(.system(size: 38, weight: .heavy))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metaRow

                if !shown.genres.isEmpty {
                    Text(shown.genres.prefix(6).joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }

                if let synopsis = shown.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(expanded ? nil : 6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if synopsis.count > 420 {
                        Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }

                if title.type == .movies {
                    movieControls
                } else {
                    showControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            if let year = shown.year { Text(String(year)) }
            if let minutes = shown.runtime {
                Text(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min")
            }
            if let n = details?.seasons.count ?? shown.seasonCount, n > 0, title.type == .shows {
                Text(n == 1 ? "1 season" : "\(n) seasons")
            }
            if let stars = shown.stars, let rating = shown.rating {
                HStack(spacing: 6) {
                    RatingStars(rating: stars, size: 12)
                    Text("\(Int(rating.rounded()))%").foregroundStyle(Theme.secondary)
                }
                .help(shown.votes.map { "\($0.formatted()) votes" } ?? "")
            }
            if let cert = shown.certification {
                Text(cert)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiary))
            }
            if let source = model.apiBrowse.source { Text("from \(source.name)").foregroundStyle(Theme.tertiary) }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private var movieControls: some View {
        let options = check.ordered(shown.options)
        let key = shown.libraryKey
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let best = options.first {
                    Button {
                        play(best)
                    } label: {
                        Label(model.library.resumePosition(key).map { "Resume from \(formatTime($0))" } ?? "Watch Now", systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
                let watched = model.library.isWatched(key)
                Button {
                    model.library.setWatched(key, !watched)
                } label: {
                    Label(watched ? "Watched" : "Mark Watched", systemImage: watched ? "eye.fill" : "eye")
                }
                .buttonStyle(AccentButtonStyle(prominent: false))
                imdbButton
            }

            if !options.isEmpty {
                optionList(options, heading: options.count == 1 ? "Torrent" : "Options · most seeds first") { play($0) }
            } else if details == nil && error == nil {
                ProgressView()
            } else if let error {
                loadError(error)
            } else {
                Text("This source lists no torrents for this movie.").foregroundStyle(Theme.secondary)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var showControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let details {
                HStack(spacing: 12) {
                    if let next = upNext(details), let best = check.ordered(next.options).first {
                        Button {
                            play(best, episode: next)
                        } label: {
                            Label(playLabel(details, next), systemImage: "play.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    }
                    imdbButton
                }
                if details.episodes.isEmpty {
                    Text("This source lists no episodes for this show.").foregroundStyle(Theme.secondary)
                } else if upNext(details) == nil {
                    Text("This source lists no torrents for this show's episodes.").foregroundStyle(Theme.secondary)
                }
            } else if let error {
                loadError(error)
            } else {
                ProgressView()
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var imdbButton: some View {
        if let url = shown.imdbURL {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(AccentButtonStyle(prominent: false))
            .help("Open on IMDb")
        }
    }

    private func loadError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Couldn't load this title: \(message)").foregroundStyle(Theme.secondary)
            Button("Try Again") { Task { await load() } }.buttonStyle(AccentButtonStyle())
        }
    }

    private func optionList(_ options: [FeedOption], heading: String, play: @escaping (FeedOption) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            VStack(spacing: 2) {
                ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                    OptionRow(option: option, best: i == 0, check: check) { play(option) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        }
    }

    // MARK: Episodes

    private func episodes(_ details: APIDetails) -> some View {
        let current = season ?? details.seasons.first ?? 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text("Episodes").font(.system(size: 20, weight: .bold))
                if details.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(details.seasons, id: \.self) { s in
                                Button {
                                    season = s
                                    openEpisodeID = nil
                                } label: {
                                    Text("Season \(s)")
                                        .font(.system(size: 12, weight: s == current ? .bold : .medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(s == current ? Theme.accent : Color.white.opacity(0.08)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            VStack(spacing: 2) {
                ForEach(details.episodes(in: current)) { episode in
                    APIEpisodeRow(
                        episode: episode,
                        key: details.key(episode),
                        best: check.ordered(episode.options).first,
                        open: openEpisodeID == episode.id,
                        toggle: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                openEpisodeID = openEpisodeID == episode.id ? nil : episode.id
                            }
                            if openEpisodeID == episode.id { check.run(episode.options) }
                        },
                        play: { option in play(option, episode: episode) }
                    ) {
                        let options = check.ordered(episode.options)
                        VStack(alignment: .leading, spacing: 10) {
                            if let overview = episode.overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.system(size: 13))
                                    .lineSpacing(2)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            if options.isEmpty {
                                Text("No torrents for this episode.").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                            } else {
                                optionList(options, heading: options.count == 1 ? "Torrent" : "Options · most seeds first") {
                                    play($0, episode: episode)
                                }
                            }
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        }
    }

    /// Where to pick a show up: an episode left part-way, else the first one
    /// not yet watched.
    private func upNext(_ details: APIDetails) -> APIEpisode? {
        let playable = details.episodes.filter { !$0.options.isEmpty }
        return playable.first { model.library.resumePosition(details.key($0)) != nil }
            ?? playable.first { !model.library.isWatched(details.key($0)) }
            ?? playable.first
    }

    private func playLabel(_ details: APIDetails, _ episode: APIEpisode) -> String {
        if let pos = model.library.resumePosition(details.key(episode)) { return "Resume \(episode.tag) from \(formatTime(pos))" }
        return "Play \(episode.tag)"
    }

    private func play(_ option: FeedOption, episode: APIEpisode? = nil) {
        model.playAPI(details ?? APIDetails(title: shown, episodes: []), episode: episode, option: option)
    }

    private func load() async {
        error = nil
        if details == nil { check.run(title.options) }
        guard let base = model.apiBrowse.query?.base else {
            error = APIError.badURL.localizedDescription
            return
        }
        do {
            let d = try await APIClient.details(base, title)
            details = d
            if d.title.options != title.options { check.run(d.title.options) }
            if season == nil, let next = upNext(d) {
                season = next.season
                openEpisodeID = next.id
                check.run(next.options)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct APIEpisodeRow<Detail: View>: View {
    @Environment(AppModel.self) private var model
    let episode: APIEpisode
    let key: String
    let best: FeedOption?
    let open: Bool
    let toggle: () -> Void
    let play: (FeedOption) -> Void
    @ViewBuilder let detail: () -> Detail
    @State private var hovering = false

    var body: some View {
        let watched = model.library.isWatched(key)
        let progress = model.library.progress[key]?.fraction
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text("\(episode.episode)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if let progress {
                        ProgressView(value: progress).tint(Theme.accent).frame(maxWidth: 220)
                    }
                }
                Spacer()
                if let aired = episode.aired {
                    Text(aired.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(Theme.tertiary).font(.system(size: 12))
                }
                if let best {
                    Text([best.release.quality, best.entry.seeders.map { "\($0) seeds" }].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(Theme.tertiary)
                        .font(.system(size: 12))
                }
                Button {
                    model.library.setWatched(key, !watched)
                } label: {
                    Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(watched ? Theme.accent : Theme.tertiary)
                }
                .buttonStyle(.plain)
                .help(watched ? "Mark as unwatched" : "Mark as watched")
                Button {
                    if let best { play(best) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11))
                        .padding(8)
                        .background(Circle().fill(hovering || open ? Theme.accent : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(best == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let best { play(best) } }
            .onTapGesture(perform: toggle)

            if open {
                detail()
                    .padding(.leading, 56)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(open ? Color.white.opacity(0.08) : (hovering ? Color.white.opacity(0.04) : .clear)))
        .onHover { hovering = $0 }
    }
}
