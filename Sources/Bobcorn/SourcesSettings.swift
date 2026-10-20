import SwiftUI

/// Settings → Sources: the user's own torrent feeds and catalog APIs.
struct SourcesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CustomSource?

    var body: some View {
        let store = model.sources
        Form {
            Section {
                if store.sources.isEmpty {
                    Text("No sources yet. Bobcorn's own catalog is always available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.sources) { source in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { source.enabled },
                            set: {
                                store.setEnabled(source.id, $0)
                                model.sourcesChanged()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name).fontWeight(.medium)
                            Text(source.feedURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if source.kind == .api {
                            Text("API")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.6)))
                                .help("Catalog API")
                        } else if source.canSearch {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .help("Searchable")
                        }
                        Button("Edit") { editing = source }
                        Button {
                            store.remove(source.id)
                            model.sourcesChanged()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("A source is an RSS or Atom feed that lists torrents as magnet links or .torrent files, or a catalog API that serves movies and shows as JSON. Enabled sources appear under Sources in the top bar. Only add sources you have the right to download from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Add Source…") { editing = CustomSource(name: "", feedURL: "") }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { source in
            SourceEditor(source: source) { saved in
                store.upsert(saved)
                model.sourcesChanged()
            }
        }
    }
}

private struct SourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: CustomSource
    let onSave: (CustomSource) -> Void
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    init(source: CustomSource, onSave: @escaping (CustomSource) -> Void) {
        _source = State(initialValue: source)
        self.onSave = onSave
    }

    private var searchProblem: String? {
        let s = source.searchURL.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return source.canSearch ? nil : "The search URL needs {query} where the search words go."
    }

    private var address: URL? { source.kind == .api ? source.apiBase : source.feed }
    private var valid: Bool { address != nil && (source.kind == .api || searchProblem == nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Type", selection: $source.kind) {
                    Text("RSS or Atom feed").tag(CustomSource.Kind.feed)
                    Text("Catalog API").tag(CustomSource.Kind.api)
                }
                .onChange(of: source.kind) { testResult = nil }
                TextField("Name", text: $source.name, prompt: Text("Shown in the top bar"))
                if source.kind == .api {
                    TextField("Base URL", text: $source.feedURL, prompt: Text("https://api.example.org"))
                    Text("Bobcorn reads /movies/<page>, /shows/<page>, /movie/<imdb_id> and /show/<imdb_id> under this address, and searches, filters and sorts with the API's own keywords, genre and sort parameters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Feed URL", text: $source.feedURL, prompt: Text("https://example.org/torrents.rss"))
                    TextField("Search URL", text: $source.searchURL, prompt: Text("Optional: https://example.org/search?q={query}"))
                    if let searchProblem {
                        Text(searchProblem).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("With a search URL, the search field searches this source. Without one, it filters the feed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Button(source.kind == .api ? "Test API" : "Test Feed") { test() }
                        .disabled(address == nil || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var s = source
                    s.feedURL = s.feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    s.searchURL = s.kind == .api ? "" : s.searchURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        s.name = address?.host ?? address?.lastPathComponent ?? "Source"
                    }
                    onSave(s)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private func test() {
        if source.kind == .api {
            testAPI()
            return
        }
        guard let url = source.feed else { return }
        testing = true
        testResult = nil
        Task {
            do {
                let entries = try await FeedClient.entries(from: url)
                let titles = FeedTitle.group(entries).count
                let seeded = entries.filter { $0.seeders != nil }.count
                if entries.isEmpty {
                    testResult = (false, "The feed works but lists no torrents.")
                } else {
                    testResult = (true, "\(entries.count) torrents, \(titles) titles\(seeded > 0 ? ", \(seeded) with seed counts" : "")")
                }
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }

    /// Fetches the first page of movies and of shows. An API may serve only one.
    private func testAPI() {
        guard let base = source.apiBase else { return }
        testing = true
        testResult = nil
        let id = source.id
        Task {
            async let movies = Self.firstPage(base, id, .movies)
            async let shows = Self.firstPage(base, id, .shows)
            let (m, s) = await (movies, shows)
            var found: [String] = []
            if case .success(let list) = m, !list.isEmpty {
                let seeded = list.filter { !$0.options.isEmpty }.count
                found.append("\(list.count) movies (\(seeded) with torrents)")
            }
            if case .success(let list) = s, !list.isEmpty { found.append("\(list.count) shows") }
            if !found.isEmpty {
                testResult = (true, found.joined(separator: ", ") + " on the first page")
            } else if case .failure(let error) = m {
                testResult = (false, error.localizedDescription)
            } else if case .failure(let error) = s {
                testResult = (false, error.localizedDescription)
            } else {
                testResult = (false, "The API works but lists no movies or shows.")
            }
            testing = false
        }
    }

    private static func firstPage(_ base: URL, _ id: UUID, _ type: APIMediaType) async -> Result<[APITitle], Error> {
        let q = APIQuery(sourceID: id, base: base, type: type, genre: .all, sort: .trending, search: "")
        do { return .success(try await APIClient.page(q, page: 1)) } catch { return .failure(error) }
    }
}
