/// Pairing payloads. The Swift twin of `protocol/src/pairing.ts`.
///
/// Two paths, both ending in a mutually authenticated tunnel:
///
/// - **QR** carries the machine's static public key directly, so the phone knows
///   the responder's identity before the first byte and a hostile Relay cannot
///   interpose. This is the default and needs no confirmation step.
/// - **Short code** is for people who cannot scan. The phone fetches the bundle
///   from the Relay, which could lie or use it itself, so its token only earns a
///   request: the Mac shows the requesting device's key fingerprint, and the
///   person accepts only if it matches the one this device shows.

import CryptoKit
import Foundation

/// Everything the phone needs to reach and authenticate one machine.
public struct PairingBundle: Codable, Equatable, Sendable {
    /// Payload format version.
    public let v: Int
    /// Relay base URL. Always present: it is the path that works from anywhere.
    public let relay: String
    /// LAN addresses of the machine's direct listener, best candidate first.
    public let direct: [String]?
    /// Stable per-machine identifier the Relay uses to pair the two sockets.
    public let device: String
    /// The machine's raw static public key, base64url.
    public let key: String
    /// One-time pairing token, base64url; consumed by the first handshake.
    public let token: String
    /// Display name of the machine.
    public let name: String

    public init(v: Int = 1, relay: String, direct: [String]? = nil, device: String, key: String, token: String, name: String) {
        self.v = v
        self.relay = relay
        self.direct = direct
        self.device = device
        self.key = key
        self.token = token
        self.name = name
    }

    /// The machine's static public key as raw bytes.
    public var staticKey: Data? { Data(base64url: key) }
}

/// A pairing input that could not be understood.
public struct PairingError: Error, LocalizedError, Equatable {
    public let reason: String
    public var errorDescription: String? { reason }

    public static let notALink = PairingError(reason: "That isn’t a Rowel pairing code.")
}

public enum Pairing {
    /// Characters of the typed short code: no vowels, and no 0/O/1/I/L.
    static let codeAlphabet = "BCDFGHJKMNPQRSTVWXYZ23456789"

    /// Characters in a typed short code, before the hyphen is added back.
    static let codeLength = 8

    /// Digits in the out-of-band confirmation number.
    static let confirmationDigits = 6

    /// Encode a bundle as the deep link the QR carries.
    ///
    /// The payload sits in the fragment, so it never reaches a web server even if
    /// someone opens the link in a browser instead of the app.
    /// The member order is stated rather than left to `JSONEncoder`, which backs
    /// a keyed container with a dictionary and so emits no particular order. The
    /// machine writes this link with `JSON.stringify`; matching it byte for byte
    /// is what lets the two implementations be tested against each other.
    public static func encodeLink(_ bundle: PairingBundle) -> String {
        let members: [(String, JSONValue?)] = [
            ("v", .number(Double(bundle.v))),
            ("relay", .string(bundle.relay)),
            ("direct", bundle.direct.map { .array($0.map(JSONValue.string)) }),
            ("device", .string(bundle.device)),
            ("key", .string(bundle.key)),
            ("token", .string(bundle.token)),
            ("name", .string(bundle.name)),
        ]
        guard let data = try? orderedJSON(members) else { return "" }
        return "rowel://pair#\(data.base64urlString)"
    }

    /// Decode a scanned or pasted pairing link.
    public static func decodeLink(_ link: String) throws -> PairingBundle {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("rowel://pair"), let hash = trimmed.firstIndex(of: "#") else {
            throw PairingError.notALink
        }
        let payload = String(trimmed[trimmed.index(after: hash)...])
        guard let data = Data(base64url: payload) else { throw PairingError.notALink }
        guard let bundle = try? JSONDecoder().decode(PairingBundle.self, from: data) else {
            throw PairingError(reason: "That pairing code is damaged. Ask your Mac for a new one.")
        }
        guard !bundle.relay.isEmpty, !bundle.device.isEmpty, !bundle.token.isEmpty,
              bundle.staticKey?.count == noiseKeyLength else {
            throw PairingError(reason: "That pairing code is incomplete. Ask your Mac for a new one.")
        }
        return bundle
    }

    /// Normalize a user-typed short code for comparison.
    ///
    /// People type spaces, forget the hyphen, and hold shift or don't. All of
    /// those are the same code.
    public static func normalizeShortCode(_ input: String) -> String {
        let stripped = strippedCode(input)
        guard stripped.count == codeLength else { return stripped }
        let split = stripped.index(stripped.startIndex, offsetBy: codeLength / 2)
        return "\(stripped[..<split])-\(stripped[split...])"
    }

    /// Whether a typed code is complete and could be claimed.
    ///
    /// Length is checked on the stripped form, not the normalized one: a nine
    /// character code normalizes to nine characters unchanged, which is the same
    /// length as a correct code plus its hyphen, and a check on the normalized
    /// form would wave it through.
    public static func isCompleteShortCode(_ input: String) -> Bool {
        let stripped = strippedCode(input)
        guard stripped.count == codeLength else { return false }
        return stripped.allSatisfy { codeAlphabet.contains($0) }
    }

    /// A typed code with the formatting removed: uppercase, letters and digits only.
    private static func strippedCode(_ input: String) -> String {
        String(input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// Six-digit confirmation number for the short-code path.
    ///
    /// Derived from the completed handshake hash, so it matches on both ends
    /// exactly when nobody is in the middle.
    public static func confirmationNumber(handshakeHash: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("rowel-confirm".utf8))
        hasher.update(data: handshakeHash)
        let digest = Data(hasher.finalize())
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let modulus = UInt32(pow(10.0, Double(confirmationDigits)))
        return String(format: "%0\(confirmationDigits)u", value % modulus)
    }

    /// Short, human-comparable rendering of a peer's static key for the trust screen.
    public static func keyFingerprint(_ publicKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("rowel-identity".utf8))
        hasher.update(data: publicKey)
        let hex = Data(hasher.finalize()).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4)
            return String(hex[start..<end])
        }.joined(separator: "-")
    }
}

// MARK: - base64url

public extension Data {
    /// Decode unpadded base64url, the encoding every Rowel identifier uses.
    init?(base64url: String) {
        var text = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: text) else { return nil }
        self = data
    }

    /// Encode as unpadded base64url.
    var base64urlString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
