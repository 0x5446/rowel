/// What the socket will accept before anything of ours gets a say.
///
/// `URLSessionWebSocketTask` caps inbound messages at one mebibyte unless told
/// otherwise, and the failure is not loud: the receive throws, the tunnel
/// reconnects, and the call that asked for the big thing comes back as a bare
/// `fetch failed`. Everything upstream — the Bridle's frame check, the relay's
/// 32 MiB runtime ceiling — had already agreed the frame was carriable, so no
/// layer that logs had anything to say about it.
///
/// It cost a 1.7 MB image attachment that drew the grey placeholder forever,
/// in the app and in a screenshot published to the App Store, plus a history
/// page failure that went unexplained for days.

import XCTest
@testable import Rowel

final class CarrierTests: XCTestCase {
    /// One mebibyte: the default this test exists to keep from coming back.
    private static let urlSessionDefault = 1024 * 1024

    func testTheCarrierAcceptsFramesTheRestOfTheStackWillSend() throws {
        // No server: `open` starts the handshake in the background and the
        // ceiling is set on the task before that can matter, so this reads the
        // configuration rather than the connection.
        let carrier = WebSocketCarrier.open(url: URL(string: "wss://127.0.0.1:1/x")!, timeout: 1)
        defer { carrier.close("test over") }

        XCTAssertGreaterThan(carrier.ceiling, Self.urlSessionDefault,
                             "the socket is back on the URLSession default and will drop big frames")
        XCTAssertEqual(carrier.ceiling, WebSocketCarrier.maxFrameBytes,
                       "the ceiling the app announces is not the one the socket enforces")
    }

    /// The number itself has to match the substrate, not just exceed the default.
    ///
    /// The Workers runtime closes a WebSocket that receives more than 32 MiB
    /// with a 1009 before the relay's own code runs — `RUNTIME_MAX_FRAME_BYTES`
    /// in `relay-worker/src/limits.ts` is that limit, and the Bridle refuses to
    /// send past it. Setting a smaller number here would reintroduce the same
    /// bug at a higher threshold; a larger one would promise to carry frames
    /// that the relay drops on the floor.
    func testTheCeilingMatchesTheRelay() {
        XCTAssertEqual(WebSocketCarrier.maxFrameBytes, 32 * 1024 * 1024)
    }
}
