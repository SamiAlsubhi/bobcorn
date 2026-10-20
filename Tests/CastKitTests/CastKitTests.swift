import Network
import XCTest
@testable import CastKit

final class CastMessageTests: XCTestCase {
    func testRoundTripsThroughTheWireFormat() throws {
        let m = CastMessage(source: "sender-0", destination: "receiver-0", namespace: CastMessage.Namespace.receiver,
                            json: ["type": "LAUNCH", "appId": "CC1AD845", "requestId": 1])
        var wire = m.framed + CastMessage(source: "a", destination: "b", namespace: "n", payload: "{}").framed
        wire += Data([0, 0, 0, 9, 1]) // the start of a third, not here yet
        let decoded = CastMessage.unframe(&wire)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0], m)
        XCTAssertEqual(decoded[0].type, "LAUNCH")
        XCTAssertEqual(wire.count, 5)
    }

    func testEncodesTheFieldsReceiversExpect() {
        let body = CastMessage(source: "s", destination: "d", namespace: "n", payload: "p").encoded
        // version 0, source, destination, namespace, payload type 0, payload
        XCTAssertEqual([UInt8](body), [0x08, 0x00, 0x12, 1, 0x73, 0x1A, 1, 0x64, 0x22, 1, 0x6E, 0x28, 0x00, 0x32, 1, 0x70])
    }
}

/// A stand-in for a Cast device's receiver, over plain TCP.
private final class FakeReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-receiver")
    private var connection: NWConnection?
    private var buffer = Data()
    private let lock = NSLock()
    private var log: [CastMessage] = []
    var onMessage: ((CastMessage, FakeReceiver) -> Void)?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connection = c
            c.start(queue: self.queue)
            self.receive()
        }
        return try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { c.resume(returning: listener.port!.rawValue) }
                if case .failed(let e) = state { c.resume(throwing: e) }
            }
            listener.start(queue: queue)
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, _ in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            for m in CastMessage.unframe(&self.buffer) {
                self.lock.lock()
                self.log.append(m)
                self.lock.unlock()
                self.onMessage?(m, self)
            }
            if !complete { self.receive() }
        }
    }

    func send(from source: String, namespace: String, _ json: [String: Any]) {
        let m = CastMessage(source: source, destination: "*", namespace: namespace, json: json)
        connection?.send(content: m.framed, completion: .contentProcessed { _ in })
    }

    var messages: [CastMessage] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func stop() { listener.cancel() }
}

final class CastSessionTests: XCTestCase {
    func testLaunchesLoadsPlaysAndStops() async throws {
        let receiver = try FakeReceiver()
        receiver.onMessage = { m, r in
            switch m.type {
            case "LAUNCH":
                r.send(from: "receiver-0", namespace: CastMessage.Namespace.receiver, [
                    "type": "RECEIVER_STATUS",
                    "status": ["applications": [["appId": "CC1AD845", "transportId": "web-5", "sessionId": "s-1"]]],
                ])
            case "LOAD":
                let start = m.json?["currentTime"] as? Double ?? 0
                r.send(from: "web-5", namespace: CastMessage.Namespace.media, [
                    "type": "MEDIA_STATUS",
                    "status": [["mediaSessionId": 7, "playerState": "PLAYING", "currentTime": start, "media": ["duration": 100.0]]],
                ])
            case "SEEK":
                r.send(from: "web-5", namespace: CastMessage.Namespace.media, [
                    "type": "MEDIA_STATUS",
                    "status": [["mediaSessionId": 7, "playerState": "IDLE", "idleReason": "FINISHED", "currentTime": 100.0]],
                ])
            default:
                break
            }
        }
        let port = try await receiver.start()
        defer { receiver.stop() }

        let device = CastDevice(id: "fake", name: "Fake TV", model: nil, endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let session = CastSession(device: device, useTLS: false)
        let playing = expectation(description: "playing")
        let finished = expectation(description: "finished")
        // Status repeats as the position moves.
        playing.assertForOverFulfill = false
        finished.assertForOverFulfill = false
        let states = StateLog()
        session.onStatus = { status in
            states.append(status)
            if status.state == .playing { playing.fulfill() }
            if status.state == .finished { finished.fulfill() }
        }

        let address = try await session.connect()
        XCTAssertEqual(address, "127.0.0.1")
        session.load(CastMedia(url: URL(string: "http://127.0.0.1:9/s/t/index.m3u8")!, contentType: "application/x-mpegurl",
                               title: "Film", imageURL: URL(string: "https://img.example/p.jpg"), startTime: 42))
        await fulfillment(of: [playing], timeout: 5)
        XCTAssertEqual(states.last?.currentTime, 42)
        XCTAssertEqual(states.last?.duration, 100)

        session.seek(to: 99)
        await fulfillment(of: [finished], timeout: 5)
        session.stop()
        try await Task.sleep(nanoseconds: 600_000_000)

        let sent = receiver.messages
        XCTAssertEqual(sent.first?.type, "CONNECT")
        XCTAssertTrue(sent.contains { $0.type == "CONNECT" && $0.destination == "web-5" })
        let load = try XCTUnwrap(sent.first { $0.type == "LOAD" })
        XCTAssertEqual(load.destination, "web-5")
        let media = try XCTUnwrap(load.json?["media"] as? [String: Any])
        XCTAssertEqual(media["contentId"] as? String, "http://127.0.0.1:9/s/t/index.m3u8")
        XCTAssertEqual(media["hlsSegmentFormat"] as? String, "fmp4")
        XCTAssertEqual(sent.first { $0.type == "SEEK" }?.json?["mediaSessionId"] as? Int, 7)
        XCTAssertEqual(sent.last { $0.type == "STOP" }?.json?["sessionId"] as? String, "web-5")
    }

    func testTimesOutWithoutADevice() async throws {
        // A port nothing listens on refuses the connection at once.
        let device = CastDevice(id: "none", name: "Nobody", model: nil, endpoint: .hostPort(host: "127.0.0.1", port: 9))
        do {
            _ = try await CastSession(device: device, useTLS: false).connect()
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error is CastError)
        }
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [CastStatus] = []
    func append(_ s: CastStatus) { lock.lock(); states.append(s); lock.unlock() }
    var last: CastStatus? { lock.lock(); defer { lock.unlock() }; return states.last }
}

/// Against a real device: CAST_HOST=<address> swift test --filter RealDeviceTests
final class RealDeviceTests: XCTestCase {
    func testConnectsToARealDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        let device: CastDevice
        if env["CAST_BROWSE"] != nil {
            // The way the app finds it: over Bonjour.
            let browser = CastBrowser()
            let found = expectation(description: "found")
            let box = DeviceBox()
            browser.onChange = { devices in
                if let d = devices.first, box.device == nil { box.device = d; found.fulfill() }
            }
            browser.start()
            await fulfillment(of: [found], timeout: 10)
            browser.stop()
            device = try XCTUnwrap(box.device)
            print("[cast] found \(device.name) at \(device.endpoint)")
        } else {
            guard let host = env["CAST_HOST"] else { throw XCTSkip("set CAST_HOST or CAST_BROWSE") }
            device = CastDevice(id: "real", name: host, model: nil, endpoint: .hostPort(host: NWEndpoint.Host(host), port: 8009))
        }
        let session = CastSession(device: device)
        session.trace = { print("[cast] \($0)") }
        let address = try await session.connect()
        print("[cast] connected; this Mac is \(address)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        session.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

private final class DeviceBox: @unchecked Sendable { var device: CastDevice? }
