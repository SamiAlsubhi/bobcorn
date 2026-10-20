import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar()
                ZStack {
                    switch model.section {
                    case .myList: MyListView()
                    case .sources:
                        if model.currentSource?.kind == .api { APIGrid() } else { FeedGrid() }
                    default: BrowseGrid()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let item = model.selectedItem {
                DetailView(item: item)
                    .id(item.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    .zIndex(1)
            }

            if let title = model.selectedFeedTitle {
                FeedDetailView(title: title)
                    .id(title.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    .zIndex(1)
            }

            if let title = model.selectedAPITitle {
                APIDetailView(title: title)
                    .id(title.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
                    .zIndex(1)
            }

            if let playback = model.playback {
                PlayerScreen(controller: playback)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .frame(minWidth: 920, minHeight: 600)
        .animation(.easeInOut(duration: 0.22), value: model.selectedItem?.id)
        .animation(.easeInOut(duration: 0.22), value: model.selectedFeedTitle?.id)
        .animation(.easeInOut(duration: 0.22), value: model.selectedAPITitle?.id)
        .sheet(item: $model.torrentFlow, onDismiss: nil) { flow in
            TorrentSheet(flow: flow)
        }
        .sheet(isPresented: $model.magnetPromptVisible) {
            MagnetPrompt()
        }
        .alert("Bobcorn", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear { if model.browse.items.isEmpty { model.reloadBrowse() } }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in AppModel.shared.open(url: url) }
                }
                return true
            }
            if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { text, _ in
                    guard let text, text.hasPrefix("magnet:") else { return }
                    Task { @MainActor in AppModel.shared.openMagnet(text) }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 18) {
            HStack(spacing: 7) {
                Image(systemName: "popcorn.fill")
                    .foregroundStyle(Theme.accent)
                Text("Bobcorn")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
            }
            .padding(.trailing, 6)

            HStack(spacing: 4) {
                ForEach(model.visibleSections) { section in
                    SectionTab(section: section, selected: model.section == section) {
                        model.selectedItem = nil
                        model.selectedFeedTitle = nil
                        model.selectedAPITitle = nil
                        model.section = section
                    }
                }
            }

            if model.section == .sources {
                Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
                Menu {
                    Picker("Source", selection: Binding(get: { model.currentSource?.id }, set: { model.sourceID = $0 })) {
                        ForEach(model.sources.enabled) { s in Text(s.name).tag(Optional(s.id)) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    SettingsLink { Text("Manage Sources…") }
                } label: {
                    FilterLabel(title: "Source", value: model.currentSource?.name ?? "None")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                if model.currentSource?.kind != .api {
                    Menu {
                        Picker("Sort by", selection: $model.feedSort) {
                            ForEach(FeedSort.allCases) { s in Text(s.title).tag(s) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        FilterLabel(title: "Sort by", value: model.feedSort.title)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            } else if model.section != .myList {
                Divider().frame(height: 18).overlay(Color.white.opacity(0.15))
                Menu {
                    Picker("Genre", selection: $model.genre) {
                        ForEach(model.section.genres) { g in Text(g.name).tag(g) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterLabel(title: "Genre", value: model.genre.name)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Menu {
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(SortOption.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterLabel(title: "Sort by", value: model.sort.title)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                TextField(model.section == .sources && model.currentSource?.canSearch != true ? "Filter" : "Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .frame(width: 170)
                    .onSubmit { model.reloadBrowse() }
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))

            Button {
                model.magnetPromptVisible = true
            } label: {
                Image(systemName: "link.badge.plus")
            }
            .buttonStyle(.plain)
            .help("Open a magnet link or torrent (⇧⌘O)")

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.leading, 86) // the window's traffic lights
        .padding(.trailing, 18)
        .frame(height: 54)
        .background(WindowDragArea())
        .background(Theme.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.4)).frame(height: 1) }
        .onChange(of: model.searchFocusRequest) { searchFocused = true }
    }
}

private struct SectionTab: View {
    let section: CatalogSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(section.title)
                .font(.system(size: 13, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : (hovering ? .white.opacity(0.85) : Theme.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 16)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(selected ? Theme.accent : .clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct FilterLabel: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(Theme.tertiary)
            Text(value).fontWeight(.semibold)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Browse grid

struct BrowseGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        let browse = model.browse
        ScrollView {
            if !model.searchText.isEmpty || browse.total > 0 {
                HStack {
                    Text(model.searchText.isEmpty ? "\(model.genre.name == "All" ? model.section.title : model.genre.name)" : "Results for “\(model.searchText)”")
                        .font(.system(size: 20, weight: .bold))
                    if browse.total > 0 {
                        Text("\(browse.total.formatted()) titles")
                            .foregroundStyle(Theme.tertiary)
                            .padding(.leading, 4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
            }

            LazyVGrid(columns: columns, spacing: 26) {
                ForEach(browse.items) { item in
                    PosterCard(item: item)
                        .onAppear {
                            if let i = browse.items.firstIndex(of: item), i >= browse.items.count - 18 { browse.loadMore() }
                        }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Group {
                if browse.isLoading {
                    ProgressView().controlSize(.regular).padding(30)
                } else if let error = browse.error {
                    VStack(spacing: 10) {
                        Text("Couldn't reach the Internet Archive").font(.headline)
                        Text(error).foregroundStyle(Theme.secondary).font(.callout)
                        Button("Try Again") { browse.retry() }.buttonStyle(AccentButtonStyle())
                    }
                    .padding(40)
                } else if browse.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film.stack").font(.system(size: 34)).foregroundStyle(Theme.tertiary)
                        Text("Nothing found").font(.headline)
                        Text("Try another genre or search.").foregroundStyle(Theme.secondary)
                    }
                    .padding(60)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.automatic)
    }
}

struct PosterCard: View {
    @Environment(AppModel.self) private var model
    let item: CatalogItem
    var progress: Double? = nil
    @State private var hovering = false

    var body: some View {
        let favorite = model.library.isFavorite(item.id)
        let watched = model.library.isWatched(item.id)
        Button {
            model.selectedItem = item
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { RemoteImage(url: item.posterURL) }
                    .overlay {
                        ZStack {
                            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            VStack(spacing: 10) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white, Theme.accent)
                                if let rating = item.rating {
                                    VStack(spacing: 3) {
                                        RatingStars(rating: rating)
                                        Text(String(format: "%.1f / 5", rating))
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                }
                            }
                        }
                        .opacity(hovering ? 1 : 0)
                    }
                    .overlay(alignment: .topTrailing) {
                        if favorite || hovering {
                            Button {
                                model.library.toggleFavorite(item)
                            } label: {
                                Image(systemName: favorite ? "heart.fill" : "heart")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(favorite ? Theme.accent : .white)
                                    .padding(7)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .padding(7)
                            .help(favorite ? "Remove from My List" : "Add to My List")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if watched {
                            Image(systemName: "eye.fill")
                                .font(.system(size: 10, weight: .bold))
                                .padding(6)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .padding(7)
                                .help("Watched")
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.white.opacity(0.25))
                                    Rectangle().fill(Theme.accent).frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(hovering ? 0.6 : 0.35), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                    .scaleEffect(hovering ? 1.035 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                    Text(item.year.map(String.init) ?? " ")
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
            Button(favorite ? "Remove from My List" : "Add to My List") { model.library.toggleFavorite(item) }
            Button(watched ? "Mark as Unwatched" : "Mark as Watched") { model.library.setWatched(item.id, !watched) }
            Divider()
            Button("Open on archive.org") { NSWorkspace.shared.open(item.pageURL) }
        }
    }
}

// MARK: - My List

struct MyListView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        let continuing = model.library.continueWatching
        let favorites = model.library.favorites
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Continue Watching").font(.system(size: 20, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(continuing, id: \.key) { entry in
                                if let item = entry.progress.item {
                                    PosterCard(item: item, progress: entry.progress.fraction)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Favorites").font(.system(size: 20, weight: .bold))
                    if favorites.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "heart").foregroundStyle(Theme.tertiary)
                            Text("Titles you heart show up here.").foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(favorites) { PosterCard(item: $0) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
