import CastKit
import Foundation
import Observation

/// The Chromecasts on the network, looked for while the player is open.
@MainActor
@Observable
final class CastDevices {
    private(set) var devices: [CastDevice] = []
    private let browser = CastBrowser()

    init() {
        browser.onChange = { [weak self] devices in
            MainActor.assumeIsolated { self?.devices = devices }
        }
    }

    func start() { browser.start() }

    func stop() {
        browser.stop()
        devices = []
    }
}
