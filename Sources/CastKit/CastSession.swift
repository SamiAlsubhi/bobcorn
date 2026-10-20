import Foundation
import Network

/// What to play on the device.
public struct CastMedia: Sendable {
    public var url: URL
    public var contentType: String
    public var title: String
    public var subtitle: String?
    public var imageURL: URL?
    /// Seconds to start from.
    public var startTime: Double
    /// Subtitles the device can switch between without reloading.
    public var textTracks: [CastTextTrack]
    /// The one of `textTracks` to show, if any.
    public var activeTextTrack: Int?
    /// Subtitle size, 1 being the device's own.
    public var textScale: Double

    public init(url: URL, contentType: String, title: String, subtitle: String? = nil, imageURL: URL? = nil, startTime: Double = 0,
                textTracks: [CastTextTrack] = [], activeTextTrack: Int? = nil, textScale: Double = 1) {
        self.url = url
        self.contentType = contentType
        self.title = title
        self.subtitle = subtitle
        self.imageURL = imageURL
        self.startTime = startTime
        self.textTracks = textTracks
        self.activeTextTrack = activeTextTrack
        self.textScale = textScale
    }

    var isHLS: Bool { contentType.lowercased().contains("mpegurl") }
}

/// A WebVTT subtitle file the device fetches when it's shown.
public struct CastTextTrack: Sendable, Equatable {
    /// 1 or more, unique among the media's tracks.
    public var id: Int
    public var url: URL
    public var name: String
    /// An RFC 5646 tag, which subtitles must have: "und" when unknown.
    public var language: String

    public init(id: Int, url: URL, name: String, language: String = "und") {
        self.id = id
        self.url = url
        self.name = name
        self.language = language
    }

    var json: [String: Any] {
        ["trackId": id, "type": "TEXT", "subtype": "SUBTITLES", "trackContentId": url.absoluteString,
         "trackContentType": "text/vtt", "name": name, "language": language]
    }
}

public struct CastStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case connecting
        case loading
        case buffering
        case playing
        case paused
        /// Nothing playing: stopped, or not started.
        case idle
        case finished
        /// The device's app went away or the connection dropped.
        case ended
        case failed(String)
    }

    public var state: State = .connecting
    /// Seconds.
    public var currentTime: Double = 0
    public var duration: Double?

    public init() {}
}

public enum CastError: LocalizedError {
    case timedOut
    case connection(String)
    case noLocalAddress

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "The Chromecast didn't answer."
        case .connection(let why): return "Couldn't connect to the Chromecast: \(why)"
        case .noLocalAddress: return "Couldn't find this Mac's address on the Chromecast's network."
        }
    }
}

/// A connection to one Cast device running Google's Default Media Receiver,
/// which plays a URL it's given. Status arrives on the main queue.
public final class CastSession: @unchecked Sendable {
    public let device: CastDevice
    public var onStatus: (@Sendable (CastStatus) -> Void)?
    /// Every message and state change, for diagnosing a device.
    public var trace: (@Sendable (String) -> Void)?

    /// The Default Media Receiver.
    static let appID = "CC1AD845"

    private let queue = DispatchQueue(label: "bobcorn.cast-session")
    private let useTLS: Bool
    private let senderID = "sender-\(UInt32.random(in: 1...UInt32.max))"
    private var connection: NWConnection?
    private var buffer = Data()
    private var nextRequest = 1
    private var transportID: String?
    private var mediaSessionID: Int?
    private var launching = false
    private var connected: CheckedContinuation<String, Error>?
    private var timers: [DispatchSourceTimer] = []
    private var polling = false
    private var status = CastStatus()
    private var closed = false

    public convenience init(device: CastDevice) {
        self.init(device: device, useTLS: true)
    }

    /// Tests talk to a stand-in receiver without TLS.
    init(device: CastDevice, useTLS: Bool) {
        self.device = device
        self.useTLS = useTLS
    }

    // MARK: Connecting

    /// Connects and starts the media receiver on the device. Returns this
    /// Mac's IPv4 address on the network the device is on, for URLs the
    /// device can open.
    public func connect() async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            queue.async { [self] in
                connected = c
                let tcp = NWProtocolTCP.Options()
                tcp.connectionTimeout = 10
                let params: NWParameters
                if useTLS {
                    // Cast devices present a certificate of their own making.
                    let tls = NWProtocolTLS.Options()
                    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
                    params = NWParameters(tls: tls, tcp: tcp)
                } else {
                    params = NWParameters(tls: nil, tcp: tcp)
                }
                // An IPv4 path gives an address any device can reach.
                (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
                let conn = NWConnection(to: device.endpoint, using: params)
                conn.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection = conn
                conn.start(queue: queue)
                every(15, repeating: false) { [weak self] in
                    guard self?.connected != nil else { return }
                    self?.fail(CastError.timedOut)
                }
            }
        }
    }

    private func stateChanged(_ state: NWConnection.State) {
        trace?("connection \(state)")
        switch state {
        case .ready:
            receive()
            send(CastMessage.Namespace.connection, to: "receiver-0", ["type": "CONNECT"])
            every(5) { [weak self] in self?.send(CastMessage.Namespace.heartbeat, to: "receiver-0", ["type": "PING"]) }
            launching = true
            send(CastMessage.Namespace.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.appID])
        case .failed(let error), .waiting(let error):
            fail(CastError.connection(error.localizedDescription))
        case .cancelled:
            if !closed { update { $0.state = .ended } }
        default:
            break
        }
    }

    private func fail(_ error: Error) {
        if let c = connected {
            connected = nil
            c.resume(throwing: error)
            close()
        } else if !closed {
            update { $0.state = .failed(error.localizedDescription) }
        }
    }

    private var localAddress: String? {
        guard case .hostPort(let host, _) = connection?.currentPath?.localEndpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "[\(a)]"
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    // MARK: Messages

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            for m in CastMessage.unframe(&self.buffer) { self.handle(m) }
            if complete || error != nil {
                if !self.closed { self.update { $0.state = .ended } }
                return
            }
            self.receive()
        }
    }

    private func handle(_ m: CastMessage) {
        trace?("← \(m.source) \(m.namespace.split(separator: ".").last ?? "") \(m.payload.prefix(600))")
        guard let json = m.json, let type = json["type"] as? String else { return }
        switch (m.namespace, type) {
        case (CastMessage.Namespace.heartbeat, "PING"):
            send(CastMessage.Namespace.heartbeat, to: m.source, ["type": "PONG"])
        case (CastMessage.Namespace.receiver, "RECEIVER_STATUS"):
            let apps = ((json["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
            let ours = apps.first { $0["appId"] as? String == Self.appID }
            if let transport = ours?["transportId"] as? String {
                guard transportID == nil else { return }
                transportID = transport
                launching = false
                send(CastMessage.Namespace.connection, to: transport, ["type": "CONNECT"])
                if let c = connected {
                    connected = nil
                    if let address = localAddress {
                        update { $0.state = .idle }
                        c.resume(returning: address)
                    } else {
                        c.resume(throwing: CastError.noLocalAddress)
                        close()
                    }
                }
            } else if transportID != nil, !launching {
                // Someone else took the device over, or it was stopped there.
                update { $0.state = .ended }
            }
        case (CastMessage.Namespace.receiver, "LAUNCH_ERROR"):
            fail(CastError.connection("the device wouldn't start its media player"))
        case (CastMessage.Namespace.media, "MEDIA_STATUS"):
            guard let s = (json["status"] as? [[String: Any]])?.first else { return }
            if let id = s["mediaSessionId"] as? Int { mediaSessionID = id }
            update { status in
                if let t = s["currentTime"] as? Double { status.currentTime = t }
                if let d = (s["media"] as? [String: Any])?["duration"] as? Double, d > 0 { status.duration = d }
                switch s["playerState"] as? String {
                case "PLAYING": status.state = .playing
                case "PAUSED": status.state = .paused
                case "BUFFERING", "LOADING": status.state = .buffering
                case "IDLE":
                    switch s["idleReason"] as? String {
                    case "FINISHED": status.state = .finished
                    case "ERROR": status.state = .failed("The Chromecast couldn't play this video.")
                    default: if status.state != .loading { status.state = .idle }
                    }
                default: break
                }
            }
        case (CastMessage.Namespace.media, "LOAD_FAILED"), (CastMessage.Namespace.media, "LOAD_CANCELLED"),
             (CastMessage.Namespace.media, "INVALID_REQUEST"):
            update { $0.state = .failed("The Chromecast couldn't play this video.") }
        case (CastMessage.Namespace.connection, "CLOSE"):
            if m.source == transportID { update { $0.state = .ended } }
        default:
            break
        }
    }

    private func send(_ namespace: String, to destination: String, _ json: [String: Any]) {
        var json = json
        if namespace != CastMessage.Namespace.connection && namespace != CastMessage.Namespace.heartbeat {
            json["requestId"] = nextRequest
            nextRequest += 1
        }
        let source = destination == "receiver-0" ? "sender-0" : senderID
        let m = CastMessage(source: source, destination: destination, namespace: namespace, json: json)
        trace?("→ \(destination) \(namespace.split(separator: ".").last ?? "") \(m.payload)")
        connection?.send(content: m.framed, completion: .contentProcessed { _ in })
    }

    private func update(_ change: (inout CastStatus) -> Void) {
        let before = status
        change(&status)
        guard status != before else { return }
        let snapshot = status
        DispatchQueue.main.async { [weak self] in self?.onStatus?(snapshot) }
    }

    private func every(_ seconds: Double, repeating: Bool = true, _ action: @escaping () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + seconds, repeating: repeating ? seconds : .infinity)
        t.setEventHandler(handler: action)
        t.resume()
        timers.append(t)
    }

    // MARK: Control

    public func load(_ media: CastMedia) {
        queue.async { [self] in
            guard let transportID else { return }
            mediaSessionID = nil
            update { $0.state = .loading; $0.currentTime = media.startTime; $0.duration = nil }
            var metadata: [String: Any] = ["metadataType": 0, "title": media.title]
            if let s = media.subtitle { metadata["subtitle"] = s }
            if let image = media.imageURL { metadata["images"] = [["url": image.absoluteString]] }
            var info: [String: Any] = [
                "contentId": media.url.absoluteString,
                "contentUrl": media.url.absoluteString,
                "contentType": media.contentType,
                "streamType": "BUFFERED",
                "metadata": metadata,
            ]
            if media.isHLS {
                info["hlsSegmentFormat"] = "fmp4"
                info["hlsVideoSegmentFormat"] = "fmp4"
            }
            var load: [String: Any] = ["type": "LOAD", "autoplay": true, "currentTime": media.startTime]
            if !media.textTracks.isEmpty {
                info["tracks"] = media.textTracks.map(\.json)
                info["textTrackStyle"] = Self.textStyle(scale: media.textScale)
                load["activeTrackIds"] = media.activeTextTrack.map { [$0] } ?? []
            }
            load["media"] = info
            send(CastMessage.Namespace.media, to: transportID, load)
            if !polling {
                // The device reports changes, not progress: ask each second.
                polling = true
                every(1) { [weak self] in self?.media(["type": "GET_STATUS"]) }
            }
        }
    }

    /// Shows one of the media's text tracks, or none.
    public func showTextTrack(_ id: Int?) {
        queue.async { [self] in media(["type": "EDIT_TRACKS_INFO", "activeTrackIds": id.map { [$0] } ?? []]) }
    }

    /// White with a shadow and no box, as Bobcorn draws them.
    static func textStyle(scale: Double) -> [String: Any] {
        ["fontScale": scale, "foregroundColor": "#FFFFFFFF", "backgroundColor": "#00000000",
         "edgeType": "DROP_SHADOW", "edgeColor": "#000000FF"]
    }

    public func play() { queue.async { [self] in media(["type": "PLAY"]) } }
    public func pause() { queue.async { [self] in media(["type": "PAUSE"]) } }

    public func seek(to seconds: Double) {
        queue.async { [self] in
            media(["type": "SEEK", "currentTime": max(0, seconds)])
            update { $0.currentTime = max(0, seconds) }
        }
    }

    private func media(_ json: [String: Any]) {
        guard let transportID, let mediaSessionID else { return }
        var json = json
        json["mediaSessionId"] = mediaSessionID
        send(CastMessage.Namespace.media, to: transportID, json)
    }

    /// Stops playback on the device, closes its media player and hangs up.
    public func stop() {
        queue.async { [self] in
            if let transportID { send(CastMessage.Namespace.receiver, to: "receiver-0", ["type": "STOP", "sessionId": transportID]) }
            queue.asyncAfter(deadline: .now() + 0.3) { [self] in close() }
        }
    }

    private func close() {
        closed = true
        timers.forEach { $0.cancel() }
        timers.removeAll()
        connection?.cancel()
        connection = nil
    }
}
