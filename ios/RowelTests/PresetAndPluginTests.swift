/// The agent picker and the plugin list, at the wire.
///
/// Both shapes here are measured, not designed: `agentPreset.list` and
/// `pluginInventory/list` were called against a live dsh and these fixtures
/// are what came back. The second one is the reason this file exists at all —
/// it is not a typert method but a cordis remote event, and its transport
/// rejects the payload every other method sends. A test that used a friendlier
/// made-up shape would pass against the app and fail against every real Mac.

import XCTest
@testable import Rowel

/// A transport that answers from a script.
private actor StubTransport: HarnessTransport {
    private var answers: [String: JSONValue] = [:]
    private var sent: [(method: String, payload: JSONValue)] = []

    func answer(_ method: String, _ value: JSONValue) {
        answers[method] = value
    }

    func payloads(_ method: String) -> [JSONValue] {
        sent.filter { $0.method == method }.map(\.payload)
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        sent.append((method, payload))
        guard let answer = answers[method] else {
            throw CallError(code: "not-found", message: "no script for \(method)", details: .null)
        }
        return answer
    }

    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue {
        .emptyObject
    }
}

final class PresetAndPluginTests: XCTestCase {
    // MARK: - Presets

    /// The measured `agentPreset.list` answer, abbreviated.
    private static let presetAnswer: JSONValue = .object([
        "presets": .array([
            .object(["id": .string("standard"), "trust": .string("system"), "isDefault": .bool(true),
                     "name": .string("标准模式"), "description": .string("功能完整的编码 Agent。")]),
            .object(["id": .string("minimal"), "trust": .string("system"), "isDefault": .bool(false),
                     "name": .string("极简模式"), "description": .string("双工具编码 Agent。")]),
        ]),
        "authorable": .bool(true),
        "hasDocument": .bool(true),
    ])

    func testPresetsParseTheMeasuredShape() async throws {
        let transport = StubTransport()
        await transport.answer("agentPreset.list", PresetAndPluginTests.presetAnswer)
        let presets = try await Harness(transport: transport).presets()

        XCTAssertEqual(presets.map(\.id), ["standard", "minimal"])
        XCTAssertEqual(presets[0].name, "标准模式")
        XCTAssertTrue(presets[0].isDefault)
        XCTAssertFalse(presets[1].isDefault)
    }

    /// Choosing the default sends no field at all: that is what keeps an older
    /// dsh — which predates `agentPreset` on `session.create` — working.
    func testCreateOmitsThePresetWhenNoneIsChosen() async throws {
        let transport = StubTransport()
        await transport.answer("session.create", .object(["sessionId": .string("s1")]))
        _ = try await Harness(transport: transport).createSession(cwd: "/tmp", agentPreset: nil)

        let payload = await transport.payloads("session.create").first
        XCTAssertNil(payload?["agentPreset"], "nil must mean absent, not null")
        XCTAssertEqual(payload?["cwd"]?.stringValue, "/tmp")
    }

    func testCreateCarriesTheChosenPreset() async throws {
        let transport = StubTransport()
        await transport.answer("session.create", .object(["sessionId": .string("s1")]))
        _ = try await Harness(transport: transport).createSession(cwd: "/tmp", agentPreset: "minimal")

        let payload = await transport.payloads("session.create").first
        XCTAssertEqual(payload?["agentPreset"]?.stringValue, "minimal")
    }

    // MARK: - Plugins

    func testInventorySendsTheArgsEnvelopeTheRemoteTransportDemands() async throws {
        let transport = StubTransport()
        await transport.answer("pluginInventory/list", .object(["entries": .array([])]))
        _ = try await Harness(transport: transport).pluginInventory()

        let payload = await transport.payloads("pluginInventory/list").first
        // Measured: anything else is refused with "Remote payload must contain
        // exactly one plain-object args field".
        XCTAssertNotNil(payload?["args"])
        XCTAssertEqual(payload, .object(["args": .emptyObject]))
    }

    func testInventoryParsesTheMeasuredShape() async throws {
        let transport = StubTransport()
        await transport.answer("pluginInventory/list", .object(["entries": .array([
            .object(["entryId": .string("include:llm"), "moduleName": .string("@deepseek-ai/dsh-llm"),
                     "enabled": .bool(true), "fiberPhase": .string("active")]),
            .object(["entryId": .string("include:hmr"), "moduleName": .string("@deepseek-ai/cordis-plugin-hmr"),
                     "enabled": .bool(false), "fiberPhase": .null]),
        ])]))
        let entries = try await Harness(transport: transport).pluginInventory()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].module, "@deepseek-ai/dsh-llm")
        XCTAssertTrue(entries[0].enabled)
        XCTAssertEqual(entries[0].phase, "active")
        XCTAssertFalse(entries[1].enabled)
        XCTAssertNil(entries[1].phase, "a null phase must come through as absence, not the string \"null\"")
    }

    // MARK: - Commands

    /// The measured `commands/list` answer, abbreviated.
    private static let commandAnswer: JSONValue = .array([
        .object(["name": .string("compact"), "description": .string("Compact older conversation history")]),
        .object(["name": .string("permission"),
                 "description": .string("Switch the permission preset (sandbox mode + approval policy)"),
                 "input": .object(["hint": .string("<preset>")])]),
    ])

    func testCommandsAreAskedForWithTheArgsEnvelope() async throws {
        let transport = StubTransport()
        await transport.answer("commands/list", PresetAndPluginTests.commandAnswer)
        _ = try await Harness(transport: transport).commands(sessionId: "s1")

        let payload = await transport.payloads("commands/list").first
        // A Typert remote: the arguments live under exactly one `args` object,
        // and the agent is named the way `commands/execute` names it.
        XCTAssertEqual(payload, .object(["args": .object(["agentId": .string("s1")])]))
    }

    func testCommandsParseAsCommandsWithTheirHints() async throws {
        let transport = StubTransport()
        await transport.answer("commands/list", PresetAndPluginTests.commandAnswer)
        let commands = try await Harness(transport: transport).commands(sessionId: "s1")

        XCTAssertEqual(commands.map(\.name), ["compact", "permission"])
        XCTAssertEqual(commands.map(\.kind), [.command, .command])
        XCTAssertNil(commands[0].hint, "a command that takes nothing has no hint")
        XCTAssertEqual(commands[1].hint, "<preset>")
        XCTAssertEqual(commands[1].summary, "Switch the permission preset (sandbox mode + approval policy)")
    }

    func testASkillIsNotACommandEvenUnderTheSameSlash() async throws {
        // The two lists share one namespace in the composer, and the difference
        // decides where a line is sent, so the parse has to keep them apart.
        let transport = StubTransport()
        await transport.answer("skill.list", .object(["skills": .array([
            .object(["name": .string("permission"), "description": .string("A skill that looks the same.")]),
        ])]))
        let skills = try await Harness(transport: transport).skills(sessionId: "s1")

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
