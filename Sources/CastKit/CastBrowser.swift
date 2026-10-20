import Foundation
import Network

/// A Chromecast, Google TV or speaker group that takes video.
public struct CastDevice: Identifiable, Hashable, @unchecked Sendable {
    public let id: String
    public let name: String
    public let model: String?
    public let endpoint: NWEndpoint

    public init(id: String, name: String, model: String?, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.model = model
        self.endpoint = endpoint
    }
}

/// Finds Cast devices on the local network over Bonjour.
public final class CastBrowser: @unchecked Sendable {
    /// Every device seen, on the main queue, whenever the list changes.
    public var onChange: (@Sendable ([CastDevice]) -> Void)?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "bobcorn.cast-browser")

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var byID: [String: CastDevice] = [:]
            for r in results {
                guard case .service(let service, _, _, _) = r.endpoint else { continue }
                var txt: [String: String] = [:]
                if case .bonjour(let record) = r.metadata { txt = record.dictionary }
                let id = txt["id"] ?? service
                // A device on two interfaces shows up twice.
                if byID[id] == nil {
                    byID[id] = CastDevice(id: id, name: txt["fn"] ?? service, model: txt["md"], endpoint: r.endpoint)
                }
            }
            let devices = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self?.onChange?(devices) }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
