import Foundation

/// The top-level tabs: the current source's movies and shows, and the
/// viewer's own list.
enum CatalogSection: String, CaseIterable, Identifiable, Codable {
    case movies, shows, myList, downloads

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .shows: return "TV Shows"
        case .myList: return "My List"
        case .downloads: return "Downloads"
        }
    }

    /// Shows the source picked in the top bar.
    var browsesSource: Bool { self == .movies || self == .shows }
}

struct Genre: Hashable, Identifiable, Codable {
    let name: String
    /// What the source filters by; nil for every genre.
    let clause: String?

    var id: String { name }

    init(_ name: String, _ clause: String?) {
        self.name = name
        self.clause = clause
    }

    static let all = Genre("All", nil)
}

enum HTML {
    /// Text from the bits of HTML sources put in synopses.
    static func clean(_ html: String) -> String {
        var s = html
        for br in ["<br>", "<br/>", "<br />", "</p>", "</div>"] {
            s = s.replacingOccurrences(of: br, with: "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// JSON APIs send a field as a string, a number or a list depending on the
/// item, so fields are decoded leniently.
struct Loose: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            values = [s]
        } else if let d = try? c.decode(Double.self) {
            values = [d == d.rounded() ? String(Int(d)) : String(d)]
        } else if let list = try? c.decode([Loose].self) {
            values = list.flatMap(\.values)
        } else {
            values = []
        }
    }

    var text: String? { values.first }
    var list: [String] { values }
    var int: Int? { values.first.flatMap { Int($0) ?? Double($0).map { Int($0) } } }
    var int64: Int64? { values.first.flatMap { Int64($0) } }
    var double: Double? { values.first.flatMap { Double($0) } }
}
