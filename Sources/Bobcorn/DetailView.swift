import SwiftUI
import TorrentKit

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem

    @State private var details: ItemDetails?
    @State private var error: String?
    @State private var selectedGroupID: String?
    @State private var selectedVariantID: String?
    @State private var expanded = false
    @State private var probe: SwarmProbe?
    @AppStorage(Pref.streamMode) private var streamMode = "torrent"
    @AppStorage(Pref.dataSaver) private var dataSaver = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if let details, details.videos.count > 1 {
                        EpisodeList(details: details, probe: probe, dataSaver: dataSaver, selectedGroupID: $selectedGroupID) { group in
                            model.play(details: details, group: group, variant: nil)
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 76)
                .padding(.bottom, 40)
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Button {
                model.selectedItem = nil
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
        .task(id: item.id) { await load() }
        .onDisappear {
            probe?.stop()
            probe = nil
        }
    }

    private var backdrop: some View {
        GeometryReader { geo in
            BlurredBackdrop(url: item.posterURL)
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(0.5)
                .overlay(
                    LinearGradient(
                        colors: [Theme.background.opacity(0.35), Theme.background.opacity(0.85), Theme.background],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipped()
        }
        .ignoresSafeArea()
        .overlay(alignment: .top) { WindowDragArea().frame(height: 54) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 260)
                .overlay { RemoteImage(url: item.posterURL) }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 16) {
                Text(item.title)
                    .font(.system(size: 38, weight: .heavy))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metaRow

                if let details, !details.genres.isEmpty {
                    Text(details.genres.joined(separator: " · "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                }

                if let error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Couldn't load this title: \(error)").foregroundStyle(Theme.secondary)
                        Button("Try Again") { Task { await load() } }.buttonStyle(AccentButtonStyle())
                    }
                } else if let details {
                    if !details.description.isEmpty {
                        Text(details.description)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(expanded ? nil : 6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if details.description.count > 420 {
                            Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.accent)
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    if let director = details.director {
                        HStack(spacing: 6) {
                            Text("Director").foregroundStyle(Theme.tertiary)
                            Text(director)
                        }
                        .font(.system(size: 13))
                    }
                    controls(details)
                } else {
                    ProgressView().padding(.top, 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 14) {
            if let year = details?.year ?? item.year { Text(String(year)) }
            if let runtime = details?.runtime ?? item.runtime, !runtime.isEmpty { Text(prettyRuntime(runtime)) }
            if let rating = item.rating {
                HStack(spacing: 6) {
                    RatingStars(rating: rating, size: 12)
                    Text(String(format: "%.1f", rating)).foregroundStyle(Theme.secondary)
                }
            }
            if let lang = details?.language, !lang.isEmpty {
                Text(lang.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiary))
            }
            if let license = details?.license {
                Text(license.contains("publicdomain") || license.contains("mark") ? "Public Domain" : "Creative Commons")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiary))
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private func controls(_ details: ItemDetails) -> some View {
        if let group = currentGroup(details) {
            let variant = currentVariant(group)
            VStack(alignment: .leading, spacing: 16) {
                if group.variants.count > 1 {
                    HStack(spacing: 10) {
                        Text("Quality").foregroundStyle(Theme.tertiary)
                        Picker("Quality", selection: Binding(
                            get: { variant?.id ?? "" },
                            set: { selectedVariantID = $0 }
                        )) {
                            ForEach(orderedVariants(group)) { v in
                                Text(optionLabel(v))
                                    .tag(v.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    .font(.system(size: 13))
                }

                HStack(spacing: 12) {
                    Button {
                        model.play(details: details, group: group, variant: variant)
                    } label: {
                        Label(resumeLabel(details, group), systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    let favorite = model.library.isFavorite(item.id)
                    Button {
                        model.library.toggleFavorite(item)
                    } label: {
                        Label(favorite ? "In My List" : "My List", systemImage: favorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))

                    let watched = model.library.isWatched(item.id)
                    Button {
                        model.library.setWatched(item.id, !watched)
                    } label: {
                        Label(watched ? "Watched" : "Mark Watched", systemImage: watched ? "eye.fill" : "eye")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))

                    Button {
                        NSWorkspace.shared.open(item.pageURL)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .help("Open on archive.org")
                }

                sourceBadge(details, variant: variant)
            }
            .padding(.top, 6)
        } else {
            Text("This title has no playable video files.")
                .foregroundStyle(Theme.secondary)
        }
    }

    /// Best-seeded first; among equals, what macOS plays itself, sharpest first.
    private func orderedVariants(_ group: VideoGroup) -> [VideoVariant] {
        group.variants.sorted { a, b in
            let ra = probe?.availability(a.name)?.rank ?? (0, 0, 0)
            let rb = probe?.availability(b.name)?.rank ?? (0, 0, 0)
            if ra != rb { return ra > rb }
            if a.isNative != b.isNative { return a.isNative }
            return (a.height ?? 0, a.size) > (b.height ?? 0, b.size)
        }
    }

    private func optionLabel(_ v: VideoVariant) -> String {
        var parts = [v.qualityLabel, v.fileExtension.uppercased(), formatSize(v.size)]
        if let probe {
            parts.append(probe.availability(v.name)?.seedText ?? "checking seeds…")
        }
        return parts.joined(separator: " · ") + (v.isNative ? "" : " (external player)")
    }

    private func sourceBadge(_ details: ItemDetails, variant: VideoVariant?) -> some View {
        let torrent = streamMode != "direct" && details.hasTorrent
        let availability = variant.flatMap { probe?.availability($0.name) }
        let health: Color = {
            guard torrent else { return .blue }
            guard let a = availability else { return .gray }
            if a.seeds >= 3 || (a.seeds > 0 && a.webSeeded) { return .green }
            if a.seeds > 0 || a.webSeeded { return Theme.gold }
            return a.peers > 0 ? .orange : .red
        }()
        return HStack(spacing: 8) {
            Circle()
                .fill(health)
                .frame(width: 8, height: 8)
            if torrent {
                Text("BitTorrent")
                if let a = availability {
                    Text("· \(a.seedText)\(a.peers > 0 ? " · \(a.peers) \(a.peers == 1 ? "peer" : "peers")" : "")")
                } else {
                    Text("· checking seeds…").foregroundStyle(Theme.tertiary)
                }
            } else {
                Text("Direct stream from the Internet Archive")
            }
            if let variant, !variant.isNative {
                Text("· plays in an external player").foregroundStyle(Theme.tertiary)
            }
            if !details.subtitles.isEmpty {
                Text("· subtitles").foregroundStyle(Theme.tertiary)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondary)
    }

    private func resumeLabel(_ details: ItemDetails, _ group: VideoGroup) -> String {
        let key = "ia:\(details.item.id):\(group.id)"
        if let pos = model.library.resumePosition(key) { return "Resume from \(formatTime(pos))" }
        return details.videos.count > 1 ? "Play \(group.title)" : "Watch Now"
    }

    private func currentGroup(_ details: ItemDetails) -> VideoGroup? {
        if let id = selectedGroupID, let g = details.videos.first(where: { $0.id == id }) { return g }
        return details.videos.first
    }

    private func currentVariant(_ group: VideoGroup) -> VideoVariant? {
        if let id = selectedVariantID, let v = group.variants.first(where: { $0.id == id }) { return v }
        return group.preferred(dataSaver: dataSaver)
    }

    private func load() async {
        error = nil
        do {
            let d = try await ArchiveClient.details(for: item)
            details = d
            if probe == nil, streamMode != "direct", d.hasTorrent {
                if let meta = try? await model.archiveMetainfo(identifier: d.item.id, torrentURLs: d.torrentURLs, webSeeds: d.webSeeds),
                   !Task.isCancelled, probe == nil {
                    probe = SwarmProbe(meta: meta, engine: model.engineForNewTorrent())
                }
            }
            if selectedGroupID == nil {
                // Pick up a series where it was left.
                selectedGroupID = d.videos.first { model.library.resumePosition("ia:\(item.id):\($0.id)") != nil }?.id
                    ?? d.videos.first { !model.library.isWatched("ia:\(item.id):\($0.id)") }?.id
                    ?? d.videos.first?.id
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prettyRuntime(_ raw: String) -> String {
        guard let seconds = ArchiveClient.parseDuration(raw), seconds > 0 else { return raw }
        let minutes = Int(seconds / 60)
        if raw.contains(":") || Double(raw) != nil {
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(max(1, minutes)) min"
        }
        return raw
    }
}

private struct EpisodeList: View {
    @Environment(AppModel.self) private var model
    let details: ItemDetails
    let probe: SwarmProbe?
    let dataSaver: Bool
    @Binding var selectedGroupID: String?
    let play: (VideoGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(details.item.section == .shows ? "Episodes" : "Parts")
                .font(.system(size: 20, weight: .bold))
            VStack(spacing: 2) {
                ForEach(Array(details.videos.enumerated()), id: \.element.id) { i, group in
                    EpisodeRow(
                        number: i + 1,
                        group: group,
                        key: "ia:\(details.item.id):\(group.id)",
                        seeds: group.preferred(dataSaver: dataSaver).flatMap { probe?.availability($0.name) },
                        selected: selectedGroupID == group.id,
                        select: { selectedGroupID = group.id },
                        play: { play(group) }
                    )
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        }
    }
}

private struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let number: Int
    let group: VideoGroup
    let key: String
    let seeds: FileAvailability?
    let selected: Bool
    let select: () -> Void
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        let watched = model.library.isWatched(key)
        let progress = model.library.progress[key]?.fraction
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let progress {
                    ProgressView(value: progress).tint(Theme.accent).frame(maxWidth: 220)
                }
            }
            Spacer()
            if let seeds {
                Text(seeds.seedText).foregroundStyle(Theme.tertiary).font(.system(size: 12))
            }
            if let d = group.duration { Text(formatTime(d)).foregroundStyle(Theme.tertiary).font(.system(size: 12)) }
            Button {
                model.library.setWatched(key, !watched)
            } label: {
                Image(systemName: watched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(watched ? Theme.accent : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(watched ? "Mark as unwatched" : "Mark as watched")
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .padding(8)
                    .background(Circle().fill(hovering || selected ? Theme.accent : Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.08) : (hovering ? Color.white.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: play)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}
