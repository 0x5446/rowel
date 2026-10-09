/// The agent picker, the plugin list and the command list, at the wire.
///
/// Every answer here is a recording of a real dsh 0.2 (`Fixtures/dsh-0.2`, made
/// by `e2e/scripts/capture-fixtures.mjs`), and every request is checked against
/// what the recording sent. dsh checks argument names exactly — one too many or
/// too few is `gateway/arguments-invalid` — so a friendlier made-up shape would
/// pass against the app and fail against every real Mac.

import XCTest
@testable import Rowel

/// A transport that answers from recordings, and keeps what it was sent.
private actor RecordedTransport: CallOnlyTransport {
    private var answers: [String: JSONValue] = [:]
    private var sent: [(endpoint: String, args: JSONValue)] = []

    /// Answer the recording's endpoint with the recording's result.
    func play(_ name: String) throws -> JSONValue {
        let recording = try fixture(name)
        answers[recording["endpoint"]?.stringValue ?? ""] = recording.path("result", "value") ?? .null
        return recording
    }

    func answer(_ endpoint: String, _ value: JSONValue) {
        answers[endpoint] = value
    }

    func payloads(_ endpoint: String) -> [JSONValue] {
        sent.filter { $0.endpoint == endpoint }.map(\.args)
    }

    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue {
        sent.append((endpoint, args))
        guard let answer = answers[endpoint] else {
            throw CallError(code: "not-found", message: "no recording for \(endpoint)", details: .null)
        }
        return answer
    }
}

final class PresetAndPluginTests: XCTestCase {
    // MARK: - Presets

    func testPresetsParseTheRecordedShape() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("agent-presets")
        let presets = try await Harness(transport: transport).presets()

        let sent = await transport.payloads("agentPresets/list")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(presets.map(\.id), ["standard", "ptc", "minimal", "cordis"])
        XCTAssertEqual(presets[0].name, "standard", "dsh 0.2 names a preset only by its id")
        XCTAssertTrue(presets[0].isDefault)
        XCTAssertFalse(presets[1].isDefault)
    }

    /// Choosing the default sends no field at all — nil must mean absent, not null.
    func testCreateOmitsThePresetWhenNoneIsChosen() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("session-create")
        let id = try await Harness(transport: transport).createSession(cwd: "/tmp", agentPreset: nil)

        XCTAssertEqual(id, recording.path("result", "value", "sessionId")?.stringValue)
        let payload = await transport.payloads("session/create").first
        XCTAssertEqual(payload, .object(["request": .object(["cwd": .string("/tmp")])]))
    }

    func testCreateCarriesTheChosenPreset() async throws {
        let transport = RecordedTransport()
        _ = try await transport.play("session-create")
        _ = try await Harness(transport: transport).createSession(cwd: "/tmp", agentPreset: "minimal")

        let payload = await transport.payloads("session/create").first
        XCTAssertEqual(payload?.path("request", "agentPreset")?.stringValue, "minimal")
    }

    // MARK: - Plugins

    func testInventoryIsAskedForAsTheRecordingAskedAndParses() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("plugin-inventory")
        let entries = try await Harness(transport: transport).pluginInventory()

        let sent = await transport.payloads("pluginInventory/list")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(entries.first?.module, "cordis:include")
        XCTAssertEqual(entries.first?.enabled, true)
        XCTAssertEqual(entries.first?.phase, "active")
        guard let off = entries.first(where: { !$0.enabled }) else { return XCTFail("the recording has a disabled plugin") }
        XCTAssertNil(off.phase, "a null phase must come through as absence, not the string \"null\"")
    }

    // MARK: - Sending

    /// A message with a photo, sent the way the recording sent it — the photo
    /// inline as base64, under the sender's request id.
    func testAPromptWithAPhotoIsSentAsTheRecordingSentIt() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("session-prompt")
        let request = recording.path("args", "request") ?? .null
        let image = request["content"]?.arrayValue?.last ?? .null
        try await Harness(transport: transport).prompt(
            sessionId: request["sessionId"]?.stringValue ?? "",
            requestId: request["requestId"]?.stringValue ?? "",
            text: "Hello from the fixture",
            images: [PromptImage(mediaType: image["mediaType"]?.stringValue ?? "", base64: image["data"]?.stringValue ?? "", name: image["name"]?.stringValue)],
            steer: false
        )

        guard case .object(var sent)? = await transport.payloads("session/prompt").first?["request"],
              case .object(var recorded) = request else { return XCTFail("no prompt sent") }
        // The phone's own zone, which the recording made in UTC.
        XCTAssertNotNil(sent.removeValue(forKey: "clientTimeZone"))
        recorded.removeValue(forKey: "clientTimeZone")
        XCTAssertEqual(JSONValue.object(sent), JSONValue.object(recorded))
    }

    /// A photo in the history is named, not carried; the bytes come from here.
    func testAnAttachmentIsFetchedByName() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("session-attachment")
        let request = recording.path("args", "request") ?? .null
        let fetched = try await Harness(transport: transport).attachment(
            sessionId: request["sessionId"]?.stringValue ?? "",
            attachmentId: request["attachmentId"]?.stringValue ?? ""
        )

        let sent = await transport.payloads("session/attachment")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(fetched.mediaType, "image/png")
        XCTAssertEqual(Data(base64Encoded: fetched.base64)?.count, 70)
    }

    // MARK: - Folders and search

    /// The folder browser, as dsh answers it once the browse picker is composed
    /// (the lines the app tells a person to add).
    func testAFolderListingParses() async throws {
        let transport = RecordedTransport()
        _ = try await transport.play("directory-picker-list")
        let listing = try await Harness(transport: transport).listDirectory(path: nil)

        let sent = await transport.payloads("directoryPicker/list")
        XCTAssertEqual(sent, [.emptyObject], "no path means the account's home")
        XCTAssertEqual(listing.path, listing.home)
        XCTAssertEqual(listing.crumbs.first?.path, "/")
    }

    /// Without the browse picker — dsh's default on a Mac — the call fails
    /// with the code the folder sheet turns into instructions.
    func testAMachineThatCannotBrowseSaysSoByCode() async throws {
        let recording = try fixture("directory-picker-unavailable")
        let error = CallError(recording.path("result", "error"), fallback: "")
        XCTAssertEqual(error.code, "directory-picker/unavailable")
    }

    func testSearchParsesAndSaysWhenItIsOff() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("session-search")
        let found = try await Harness(transport: transport).search(query: "zebra")

        let sent = await transport.payloads("session/search")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(found.hits.first?.snippet, "Where is the zebra crossing?")
        XCTAssertFalse(found.hasMore)

        let off = CallError(try fixture("session-search-disabled").path("result", "error"), fallback: "")
        XCTAssertTrue(off.message.contains("session search is disabled"), off.message)
    }

    // MARK: - Access

    /// What new conversations start as: read from the preset catalog, written
    /// to the `permission` settings namespace against the revision just read.
    func testChangingTheDefaultAccessSendsWhatTheRecordingSent() async throws {
        let transport = RecordedTransport()
        _ = try await transport.play("settings-describe")
        let update = try await transport.play("settings-update-permission")
        try await Harness(transport: transport).setPermission("read-only")

        let sent = await transport.payloads("settings/update")
        XCTAssertEqual(sent, [update["args"] ?? .null])

        _ = try await transport.play("permission-presets-after-update")
        let presets = try await Harness(transport: transport).permissionPresets()
        XCTAssertEqual(presets.defaults?.current, "read-only")
        XCTAssertEqual(presets.options.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
    }

    // MARK: - Commands

    func testCommandsAreAskedForAsTheRecordingAskedAndParseWithTheirHints() async throws {
        let transport = RecordedTransport()
        let recording = try await transport.play("commands-list")
        let sessionId = recording.path("args", "agentId")?.stringValue ?? ""
        let commands = try await Harness(transport: transport).commands(sessionId: sessionId)

        let sent = await transport.payloads("commands/list")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(commands.map(\.name), ["compact", "export", "feedback", "goal", "permission", "plan"])
        XCTAssertTrue(commands.allSatisfy { $0.kind == .command })
        XCTAssertNil(commands[0].hint, "a command that takes nothing has no hint")
        XCTAssertNotNil(commands.first { $0.name == "permission" }?.hint)
    }

    func testASkillIsNotACommandEvenUnderTheSameSlash() async throws {
        // The two lists share one namespace in the composer, and the difference
        // decides where a line is sent, so the parse has to keep them apart.
        let transport = RecordedTransport()
        let recording = try await transport.play("skills-list")
        await transport.answer("skills/list", .object(["skills": .array([
            .object(["name": .string("permission"), "description": .string("A skill that looks the same."), "modelInvocable": .bool(true)]),
        ])]))
        let sessionId = recording.path("args", "request", "sessionId")?.stringValue ?? ""
        let skills = try await Harness(transport: transport).skills(sessionId: sessionId)

        let sent = await transport.payloads("skills/list")
        XCTAssertEqual(sent, [recording["args"] ?? .null])
        XCTAssertEqual(skills.map(\.kind), [.skill])
        XCTAssertNil(skills[0].hint)
    }
}

// MARK: - Telling the machine where to ring, and where not to

/// `PushRegistrar` decides three things and each of them has a way to be wrong
/// quietly: whether to ask iOS at all, whether a refusal means "stop ringing
/// me", and whether the machine ever hears that it should stop.
@MainActor
final class PushRegistrarTests: XCTestCase {
    /// A registrar with the system stubbed out.
    private func registrar(authorized: Bool, asked: @escaping () -> Void = {}) -> PushRegistrar {
        PushRegistrar(authorized: { authorized }, ask: { asked() })
    }

    func testAnAuthorizedPhoneAsksTheSystemForAToken() async {
        var asks = 0
        let push = registrar(authorized: true) { asks += 1 }
        await push.refresh()
        XCTAssertEqual(asks, 1)
    }

    /// The one that mattered. The token lives in memory; the machine keeps it
    /// on disk. After a relaunch the two disagree — this object has forgotten
    /// the token while the Mac is still holding one and still ringing a phone
    /// that shows nothing. Guarding the withdrawal on "did I hand one out"
    /// meant it fired only in the session where notifications were switched
    /// off, which is the session least likely to still be running.
    func testARefusalIsAnnouncedEvenWithNoTokenInMemory() async {
        var announced: [String?] = []
        let push = registrar(authorized: false)
        push.onAnswer = { announced.append($0) }

        await push.refresh()

        XCTAssertEqual(announced.count, 1, "a fresh launch with notifications off told the machine nothing")
        XCTAssertNil(announced[0])
    }

    func testATokenIsAnnouncedOnceAndNotRepeated() {
        var announced: [String?] = []
        let push = registrar(authorized: true)
        push.onAnswer = { announced.append($0) }

        push.accept(Data([0xab, 0xcd]))
        push.accept(Data([0xab, 0xcd]))

        XCTAssertEqual(announced.compactMap { $0 }, ["abcd"], "the same token was sent twice")
    }

    /// Registration fails for reasons that say nothing about whether the phone
    /// is still reachable — no network at launch being the common one. Treating
    /// that as a withdrawal deleted a working address on the Mac because the
    /// phone happened to boot in a lift.
    func testAFailedRegistrationLeavesTheMachineAlone() {
        var announced: [String?] = []
        let push = registrar(authorized: true)
        push.onAnswer = { announced.append($0) }

        push.failed()

        XCTAssertTrue(announced.isEmpty, "a transient failure told the machine to forget the token")
        XCTAssertTrue(push.answered, "the app must still know iOS has answered")
    }
}
