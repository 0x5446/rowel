/// The two things the app asks the Relay over plain HTTP.
///
/// Claiming a typed short code, and checking whether a machine is online. Both
/// are unauthenticated by design — the Relay knows device ids and nothing else,
/// and every answer it gives is verified afterwards by the Noise handshake
/// against the key in the bundle. A bundle fetched here only ever earns a
/// request to pair: the Mac shows the requesting key and a person accepts it
/// only if it matches this device's fingerprint (see `bridle pair --code`).

import Foundation

/// Where the app looks when the person typed a code instead of scanning.
public let defaultRelayURL = "wss://rowel-relay.novabox.ai"

/// Addresses this project used to ship as the default, and no longer serves.
///
/// The relay moved off `rowel.novabox.ai` so the public site and the
/// infrastructure stop sharing a hostname: a cache rule or a WAF rule aimed at
/// the marketing pages would otherwise hit the relay too, and the relay is the
/// half that must not go down.
///
/// A paired machine carries the address it was paired at, so without this
/// every existing pairing would quietly stop connecting to a host nobody chose
/// and nobody could see. Rewritten on read. **Only these exact strings** — an
/// address someone set themselves, or their own self-hosted relay, is theirs.
public let retiredRelayURLs: Set<String> = [
    "wss://rowel.novabox.ai",
    // Lived for about an hour. `relay.` sat at the organisation level for
    // one product's infrastructure; `rowel-relay.` keeps the namespace and
    // still fits inside the free wildcard certificate, which
    // `relay.rowel.novabox.ai` would not.
    "wss://relay.novabox.ai",
]

/// The address to actually dial for a stored one.
/// - Parameter stored: whatever the pairing bundle carries.
/// - Returns: the current address, or `stored` unchanged.
public func currentRelayURL(for stored: String) -> String {
    retiredRelayURLs.contains(stored) ? defaultRelayURL : stored
}

public struct RelayDirectory: Sendable {
    public let base: String

    public init(base: String = defaultRelayURL) {
        self.base = base
    }

    /// Claim one short-code pairing offer. Codes are single-use: a second claim
    /// of the same code fails, which is what stops a shoulder-surfer from
    /// reusing one they saw.
    public func claim(code: String) async throws -> PairingBundle {
        let normalized = Pairing.normalizeShortCode(code)
        guard var components = URLComponents(string: RelayDirectory.httpBase(base)) else {
            throw PairingError(reason: "That relay address isn’t valid.")
        }
        components.path = "/v1/pair/claim"
        components.queryItems = [URLQueryItem(name: "code", value: normalized)]
        guard let url = components.url else { throw PairingError(reason: "That relay address isn’t valid.") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404: throw PairingError(reason: "That code has expired or was already used. Ask your Mac for a new one.")
        case 429: throw PairingError(reason: "Too many attempts. Wait a minute and try again.")
        default: throw PairingError(reason: "The relay couldn’t be reached (\(status)).")
        }
        guard let value = try? JSONValue(data: data), let bundle = value["bundle"] else {
            throw PairingError(reason: "The relay sent something unreadable.")
        }
        let encoded = try bundle.encoded()
        let decoded = try JSONDecoder().decode(PairingBundle.self, from: encoded)
        guard decoded.staticKey?.count == noiseKeyLength, !decoded.device.isEmpty else {
            throw PairingError(reason: "That pairing offer is incomplete. Ask your Mac for a new one.")
        }
        return decoded
    }

    /// Whether a machine is currently attached to the Relay.
    ///
    /// Advisory only. A machine on the same Wi-Fi is reachable directly whether
    /// or not the Relay has ever heard of it, so a `false` here is a hint for the
    /// status line, never a reason not to try.
    public func isOnline(device: String) async -> Bool? {
        guard var components = URLComponents(string: RelayDirectory.httpBase(base)) else { return nil }
        components.path = "/v1/machine/\(device)"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return (try? JSONValue(data: data))?["online"]?.boolValue
    }

    /// The Relay's URL as the app dials WebSockets, rewritten for plain HTTP.
    static func httpBase(_ url: String) -> String {
        if url.hasPrefix("wss://") { return "https://" + url.dropFirst("wss://".count) }
        if url.hasPrefix("ws://") { return "http://" + url.dropFirst("ws://".count) }
        return url
    }
}
