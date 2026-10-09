/// Images a message refers to but does not carry.
///
/// A history page names its images: `session.attachment` holds the bytes and
/// the event log holds only an id. The app had the parser for the reference
/// and the call for the bytes and nothing in between, so every photo in a
/// transcript drew the placeholder forever. These tests are that gap.
///
/// The `session.attachment` shape below is measured, not invented — it is what
/// a live dsh answered for a real image in a real session.

import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import Rowel

/// A transport that answers `session/attachment`, counts the asking, and can
/// be made slow enough that concurrent callers actually overlap.
private actor CountingTransport: CallOnlyTransport {
    private(set) var calls = 0
    private(set) var peak = 0
    private var active = 0
    private let data: String
    private let delay: Duration

    init(base64 data: String, delay: Duration = .zero) {
        self.data = data
        self.delay = delay
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        if delay != .zero { try? await Task.sleep(for: delay) }
        guard method == "session/attachment" else {
            throw CallError(code: "not-found", message: "no script for \(method)", details: .null)
        }
        calls += 1
        return .object([
            "attachment": .object([
                "attachmentId": payload.path("request", "attachmentId") ?? .null,
                "mediaType": .string("image/png"),
                "bytes": .number(66594),
                "name": .string("uber_cover.jpg"),
            ]),
            "data": .string(data),
        ])
    }
}

final class AttachmentTests: XCTestCase {
    /// The pixel width of the test photo, standing in for something off a camera.
    private static let sourcePixels: CGFloat = 1200

    /// A real PNG at a known pixel size. Scale 1 so points and pixels agree and
    /// the assertions below are about the decode, not about the test device.
    private static func png() -> String {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: sourcePixels, height: sourcePixels * 0.75)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()!.base64EncodedString()
    }

    @MainActor
    func testAReferencedImageIsFetchedAndDecoded() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")
        let id = "sha256:125788fcf3572ebc4adcb18361a966c8073d5a152563395b6e9814057dcd8809"

        XCTAssertNil(loader.thumbnail(id), "nothing is fetched before something needs to draw it")
        await loader.load(id, side: 56)

        XCTAssertNotNil(loader.thumbnail(id), "the placeholder is only correct until the bytes arrive")
    }

    @MainActor
    func testTheThumbnailIsSmallerThanTheImage() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")
        await loader.load("sha256:a", side: 56)

        // A phone that keeps full-size photos to fill 56-point squares runs out
        // of memory on a conversation with a handful of them. `UIImage(cgImage:)`
        // is scale 1, so `size` here is in pixels.
        let thumbnail = try XCTUnwrap(loader.thumbnail("sha256:a"))
        let longest = max(thumbnail.size.width, thumbnail.size.height)
        XCTAssertLessThan(longest, AttachmentTests.sourcePixels,
                          "the decode produced the original, not a thumbnail")
        XCTAssertLessThanOrEqual(longest, 56 * UITraitCollection.current.displayScale,
                                 "the thumbnail is larger than the square it fills")
    }

    @MainActor
    func testTheSameImageIsAskedForOnce() async throws {
        let transport = CountingTransport(base64: AttachmentTests.png())
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")

        // A transcript redraws constantly; scrolling past one photo must not
        // re-fetch it every frame.
        await loader.load("sha256:a", side: 56)
        await loader.load("sha256:a", side: 56)
        await loader.load("sha256:a", side: 56)

        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    /// The reference shape the parser has to recognise, measured off a live dsh.
    @MainActor
    func testHistoryCarriesTheIdAndNoBytes() throws {
        let conversation = Conversation(sessionId: "session-1")
        conversation.apply(event: .object([
            "type": .string("user/message"),
            "seq": .number(12),
            // `data` is the message itself, verified against a live dsh.
            "data": .object([
                "id": .string("m1"),
                "source": .object(["kind": .string("user")]),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("look at this")]),
                    .object([
                        "type": .string("image"),
                        "attachment": .object([
                            "attachmentId": .string("sha256:abc"),
                            "mediaType": .string("image/png"),
                            "bytes": .number(66594),
                        ]),
                    ]),
                ]),
            ]),
        ]))

        guard case .user(let turn)? = conversation.items.last else {
            return XCTFail("the message did not land as a user turn")
        }
        XCTAssertEqual(turn.images.map(\.id), ["sha256:abc"])
        XCTAssertNil(turn.images.first?.base64, "the bytes stay on the Mac until asked for")
    }

    @MainActor
    func testOverlappingRequestsForOneImageStillFetchOnce() async throws {
        // The sequential version above proves less than its name suggests: by
        // the time the second call runs the first has finished, so the cache
        // answers and the in-flight guard is never exercised. Slow the
        // transport down and start them together.
        let transport = CountingTransport(base64: AttachmentTests.png(), delay: .milliseconds(120))
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { @MainActor in await loader.load("sha256:a", side: 56) }
            }
        }

        let calls = await transport.calls
        XCTAssertEqual(calls, 1, "six thumbs of the same photo is still one photo")
        XCTAssertNotNil(loader.thumbnail("sha256:a"))
    }

    @MainActor
    func testOnlyTwoImagesAreInTheAirAtOnce() async throws {
        // This number is what bounds memory, not the thumbnail cache: each
        // fetch holds a whole encoded photo while it decodes, and a fast scroll
        // through a conversation full of them would otherwise start one per
        // thumb that appears.
        let transport = CountingTransport(base64: AttachmentTests.png(), delay: .milliseconds(120))
        let loader = AttachmentLoader(harness: Harness(transport: transport), sessionId: "session-1")

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask { @MainActor in await loader.load("sha256:\(index)", side: 56) }
            }
        }

        let peak = await transport.peak
        let calls = await transport.calls
        XCTAssertEqual(calls, 8, "eight distinct photos are eight fetches")
        XCTAssertLessThanOrEqual(peak, 2, "but never more than two of them at a time")
    }
}
