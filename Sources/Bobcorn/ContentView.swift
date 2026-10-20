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
                    if model.section == .myList {
                        MyListView()
                    } else if let source = model.currentSource {
                        if source.kind == .api { APIGrid() } else { FeedGrid() }
                    } else {
                        WelcomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .animation(.easeInOut(duration: 0.22), value: model.selectedFeedTitle?.id)
        .animation(.easeInOut(duration: 0.22), value: model.selectedAPITitle?.id)
        .sheet(item: $model.torrentFlow, onDismiss: nil) { flow in
            TorrentSheet(flow: flow)
        }
        .sheet(isPresented: $model.magnetPromptVisible) {
            MagnetPrompt()
        }
        .sheet(isPresented: $model.addSourceVisible) {
            SourceEditor(source: CustomSource(kind: .api, name: "", feedURL: "")) { model.addSource($0) }
        }
        .alert("Bobcorn", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear { model.reloadBrowse() }
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
                ForEach(CatalogSection.allCases) { section in
                    SectionTab(section: section, selected: model.section == section) {
                        model.selectedFeedTitle = nil
                        model.selectedAPITitle = nil
                        model.section = section
                    }
                }
            }

            if model.section != .myList, model.currentSource != nil {
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

                if model.currentSource?.kind == .api {
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
                } else {
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
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                TextField(model.currentSource?.canSearch == false ? "Filter" : "Search", text: $model.searchText)
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

// MARK: - Welcome

/// Before there's a source to browse: asks for one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "popcorn.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            if model.sources.sources.isEmpty {
                Text("Welcome to Bobcorn").font(.system(size: 26, weight: .heavy))
                Text("Add a source to browse its movies and TV shows. Bobcorn streams them over BitTorrent while they download.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button {
                    model.addSourceVisible = true
                } label: {
                    Label("Add a Source", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
                Text("A source is a catalog API or an RSS or Atom torrent feed. Only add sources you have the right to download from.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            } else {
                Text("Your sources are turned off").font(.system(size: 22, weight: .bold))
                Text("Turn one on to browse its movies and TV shows.")
                    .foregroundStyle(Theme.secondary)
                SettingsLink { Text("Manage Sources") }
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - My List

struct MyListView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 154, maximum: 210), spacing: 22, alignment: .top)]

    var body: some View {
        let continuing = model.library.continueWatching
        let saved = model.library.saved
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !continuing.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Continue Watching").font(.system(size: 20, weight: .bold))
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(continuing, id: \.key) { entry in
                                if let title = entry.progress.saved {
                                    APICard(title: APITitle(saved: title), progress: entry.progress.fraction)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Saved").font(.system(size: 20, weight: .bold))
                    if saved.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "heart").foregroundStyle(Theme.tertiary)
                            Text("Movies and shows you heart show up here.").foregroundStyle(Theme.secondary)
                        }
                        .padding(.vertical, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 26) {
                            ForEach(saved) { APICard(title: APITitle(saved: $0)) }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
