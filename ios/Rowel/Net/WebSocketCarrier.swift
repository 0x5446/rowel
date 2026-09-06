/// The dumb pipe under the tunnel.
///
/// Everything that matters to security happens a layer up, in `Tunnel`. This
/// file's only jobs are to open a WebSocket, move opaque frames, and produce a
/// close reason a person could act on — "that machine is offline" rather than
/// "Error Domain=NSPOSIXErrorDomain Code=57".

import Foundation

/// Why a carrier stopped.
public struct CarrierError: Error, LocalizedError, Equatable {
    public let reason: String
    /// The WebSocket close code, when the peer closed deliberately.
    public let closeCode: Int?

    public var errorDescription: String? { reason }

    /// Close codes the Relay defines. Anything else gets the generic wording.
    static func fromClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) -> CarrierError {
        let text = reason.flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        switch code.rawValue {
        case 4404: return CarrierError(reason: text ?? "That Mac is offline.", closeCode: 4404)
        case 4029: return CarrierError(reason: "Too many attempts. Wait a moment.", closeCode: 4029)
        case 4008: return CarrierError(reason: "That Mac already has the maximum number of devices attached.", closeCode: 4008)
        default: return CarrierError(reason: text ?? "The connection closed.", closeCode: Int(code.rawValue))
        }
    }
}

/// A duplex pipe of opaque frames, and the only thing `Tunnel` needs a socket
/// to be.
///
/// Extracted so the interesting failures can be provoked. Everything that made
/// this connection unreliable in practice is a *timing* fault — a socket that
/// stops delivering without closing, a carrier retired underneath a read in
/// flight — and none of that can be arranged against a real WebSocket. A test
/// needs to be able to say "now go quiet" and have it mean exactly that.
public protocol Carrying: AnyObject, Sendable {
    /// Send one binary frame.
    func send(_ bytes: Data) async throws
    /// Await the next binary frame.
    func receive() async throws -> Data
    /// Close, releasing whatever is underneath.
    func close(_ reason: String)
}

/// How a tunnel obtains a carrier. The default dials a real WebSocket.
public typealias CarrierOpener = @Sendable (URL, TimeInterval) -> any Carrying

/// One open WebSocket, with the message loop exposed as an async sequence.
///
/// `URLSessionWebSocketTask` buffers what arrives before you ask for it, so the
/// handshake reply cannot be lost between `send` and the first `receive`. The
/// Node reference client has to attach its listener before sending to get the
/// same property; the ordering here is the same on purpose.
public final class WebSocketCarrier: Carrying, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    private init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    /// Largest inbound frame this carrier will accept, in bytes.
    ///
    /// `URLSessionWebSocketTask` defaults to **one mebibyte** and fails the
    /// receive on anything larger, so without this line the app quietly cannot
    /// read the bigger half of its own protocol. The relay's ceiling is 32 MiB
    /// (`RUNTIME_MAX_FRAME_BYTES`, itself the Workers runtime's limit) and the
    /// Bridle refuses to send past it, so a frame that arrives here has already
    /// been judged carriable by everything upstream; the only thing this
    /// default achieved was rejecting it at the last hop.
    ///
    /// What it cost: an image attachment of any real size never loaded — a
    /// 1.7 MB sketch drew the grey placeholder forever, including in a
    /// screenshot published to the App Store — and a history page over the
    /// limit failed with `fetch failed` and no cause, which went unexplained
    /// for days because every layer that logs was under its own ceiling and
    /// had nothing to report.
    static let maxFrameBytes = 32 * 1024 * 1024

    /// What the underlying task will actually accept — read back, so a test can
    /// tell a configured ceiling from a constant nobody assigned.
    var ceiling: Int { task.maximumMessageSize }

    /// Dial one address.
    ///
    /// The task starts immediately and the TCP/TLS handshake overlaps with the
    /// caller's first `send`; a failure surfaces on the first `send` or
    /// `receive` rather than here, which is what makes carrier racing cheap.
    public static func open(url: URL, timeout: TimeInterval) -> WebSocketCarrier {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        configuration.httpShouldUsePipelining = false
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maxFrameBytes
        task.resume()
        return WebSocketCarrier(task: task, session: session)
    }

    /// Send one binary frame.
    public func send(_ bytes: Data) async throws {
        do {
            try await task.send(.data(bytes))
        } catch {
            throw translate(error)
        }
    }

    /// Await the next binary frame. Text frames are skipped: nothing in this
    /// protocol sends them, and a proxy's injected text should not be mistaken
    /// for a tunnel frame.
    public func receive() async throws -> Data {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw translate(error)
            }
            switch message {
            case .data(let bytes): return bytes
            case .string: continue
            @unknown default: continue
            }
        }
    }

    /// Close the socket and release the session.
    public func close(_ reason: String = "closed by the app") {
        task.cancel(with: .goingAway, reason: Data(reason.utf8))
        session.invalidateAndCancel()
    }

    /// Turn a URLSession failure into something a person could read, preferring
    /// the peer's own close reason when it sent one.
    private func translate(_ error: Error) -> CarrierError {
        if task.closeCode != .invalid, task.closeCode != .normalClosure {
            return CarrierError.fromClose(code: task.closeCode, reason: task.closeReason)
        }
        let urlError = error as? URLError
        switch urlError?.code {
        case .some(.notConnectedToInternet): return CarrierError(reason: "This device is offline.", closeCode: nil)
        case .some(.timedOut): return CarrierError(reason: "The Mac did not answer in time.", closeCode: nil)
        case .some(.cannotConnectToHost), .some(.cannotFindHost):
            return CarrierError(reason: "Could not reach that address.", closeCode: nil)
        case .some(.networkConnectionLost): return CarrierError(reason: "The connection dropped.", closeCode: nil)
        default: return CarrierError(reason: error.localizedDescription, closeCode: nil)
        }
    }
}
