/// The writes, and what they leave behind when the Mac says no.
///
/// Every workspace mutation here shows its result before the machine has agreed
/// to it, because a header that waits out a round trip reads as a tap that
/// missed. That trade is only safe if the undo is real, and an undo that has
/// never been run is an undo nobody has checked — so these tests are mostly
/// about failure: the name goes back, the section comes back, the conversation
/// goes back where it was, and the person is told in words.
///
/// The transport is stubbed rather than the harness, so the payloads asserted
/// here are the ones a real Bridle would receive. Their shapes come from dsh's
/// own request schemas, which is why the assertions name exact keys.

import XCTest
@testable import Rowel

/// A transport that answers from a script and refuses on command.
private actor StubTransport: HarnessTransport {
    private struct Refusal {
        var error: CallError
        /// How many calls to let through before refusing the rest.
        var after: Int
    }

    private var answers: [String: JSONValue] = [:]
    private var refusals: [String: Refusal] = [:]
    private var sent: [(method: String, payload: JSONValue)] = []

    func answer(_ method: String, _ value: JSONValue) {
        answers[method] = value
    }

    /// - Parameter after: calls to allow first, for the paths that make two.
    func fail(_ method: String, code: String = "internal", message: String, after: Int = 0) {
        refusals[method] = Refusal(error: CallError(code: code, message: message), after: after)
    }

    func payloads(_ method: String) -> [JSONValue] {
        sent.filter { $0.method == method }.map(\.payload)
    }

    func count(_ method: String) -> Int {
        sent.filter { $0.method == method }.count
    }

    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue {
        let already = sent.filter { $0.method == method }.count
        sent.append((method, payload))
        if let refusal = refusals[method], already >= refusal.after { throw refusal.error }
        return answers[method] ?? .emptyObject
    }

    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue {
        .emptyObject
    }
}

// MARK: - Fixtures

private func workspaceRow(_ id: String, path: String, title: String, sessions: [String] = []) -> JSONValue {
    .object([
        "workspaceId": .string(id),
        "path": .string(path),
        "title": .string(title),
        "sessionIds": .array(sessions.map(JSONValue.string)),
        "createdAt": .string("2026-07-25T09:41:07.000Z"),
        "updatedAt": .string("2026-07-25T09:41:07.000Z"),
    ])
}

private func sessionRow(_ id: String, cwd: String?, updatedAt: Double = 1_700_000_000_000) -> JSONValue {
    .object(dropping: [
        "sessionId": .string(id),
        "updatedAt": .number(updatedAt),
        "running": .bool(false),
        "blank": .bool(false),
        "cwd": cwd.map(JSONValue.string),
    ])
}

@MainActor
final class WorkspaceWriteTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var stub: StubTransport!

    override func setUp() {
        super.setUp()
        suiteName = "rowel.workspace.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        stub = StubTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func machine() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid",
            device: "device-1",
            key: "",
            token: "",
            name: "Test Mac"
        )
        // Never started, so nothing dials anything: the tunnel this builds sits
        // idle and every call goes to the stub instead.
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: stub
        )
    }

    /// One workspace holding one conversation, plus a stray in a folder no
    /// workspace claims. The smallest shape with something to lose.
    private func loaded() async -> MachineSession {
        await stub.answer("workspace.list", .object([
            "items": .array([workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"])]),
            "archivedSessionIds": .array([]),
        ]))
        await stub.answer("session.list", .object([
            "items": .array([
                sessionRow("s1", cwd: "/code/one"),
                sessionRow("stray", cwd: "/code/two", updatedAt: 1_699_999_000_000),
            ]),
        ]))
        let session = machine()
        await session.refreshSessions()
        return session
    }

    // MARK: - Reading

    func testListingWorkspacesIsWhatMakesTheMachineCountAsGrouping() async {
        let session = await loaded()
        XCTAssertTrue(session.canGroup)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(session.placement(for: "/code/one"), .joins(workspaceId: "w1", title: "One"))
    }

    func testTheArchiveSetArrivesWithTheWorkspaces() async {
        await stub.answer("workspace.list", .object([
            "items": .array([]),
            "archivedSessionIds": .array([.string("gone")]),
        ]))
        let session = machine()
        await session.refreshWorkspaces()
        XCTAssertEqual(session.archivedSessionIds, ["gone"])
    }

    /// The degradation that has to work. A dsh with no `workspace.list` answers
    /// HTTP 404, which the Bridle reports as `internal` — indistinguishable from
    /// a real fault, which is exactly why nothing may be concluded from it.
    func testAMachineWithoutWorkspacesStillListsItsConversationsAndSaysNothing() async {
        await stub.fail("workspace.list", message: "dsh answered HTTP 404: not found")
        await stub.answer("session.list", .object([
            "items": .array([sessionRow("s1", cwd: "/code/one")]),
        ]))
        let session = machine()
        await session.refreshSessions()

        XCTAssertEqual(session.sessions.map(\.id), ["s1"], "the list is the screen; it must fill in regardless")
        XCTAssertTrue(session.workspaces.isEmpty)
        XCTAssertFalse(session.canGroup)
        XCTAssertNil(session.problem, "a machine that cannot group is not a machine with a problem")
        XCTAssertEqual(session.placement(for: "/code/one"), .unknown)
        XCTAssertEqual(session.filing(for: session.sessions[0]), .settled)
    }

    /// A dropped call must not flatten a machine that does group. The last known
    /// list stands.
    func testALaterFailureKeepsWhatWasAlreadyKnown() async {
        let session = await loaded()
        await stub.fail("workspace.list", code: "disconnected", message: "The connection dropped.")
        await session.refreshWorkspaces()

        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertTrue(session.canGroup)
    }

    // MARK: - Making one

    func testClaimingAFolderSendsThePathAndAddsTheWorkspace() async {
        let session = await loaded()
        await stub.answer("workspace.create", .object([
            "workspace": workspaceRow("w2", path: "/code/two", title: "two"),
            "created": .bool(true),
        ]))

        let failure = await session.createWorkspace(path: "/code/two")
        let sent = await stub.payloads("workspace.create")

        XCTAssertNil(failure)
        XCTAssertEqual(sent, [.object(["path": .string("/code/two")])])
        XCTAssertEqual(session.workspaces.map(\.id), ["w2", "w1"])
        XCTAssertEqual(session.placement(for: "/code/two"), .joins(workspaceId: "w2", title: "two"))
    }

    /// The machine resolves a folder it already owns instead of erroring, and
    /// the second answer must not put a duplicate section on screen.
    func testClaimingAFolderThatIsAlreadyAWorkspaceChangesNothing() async {
        let session = await loaded()
        await stub.answer("workspace.create", .object([
            "workspace": workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"]),
            "created": .bool(false),
        ]))

        let failure = await session.createWorkspace(path: "/code/one")
        XCTAssertNil(failure)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
    }

    /// Nothing is shown before the machine agrees, because there is nothing
    /// honest to show: only the machine knows the id, and a section drawn
    /// hopefully would be a section standing over nothing.
    func testAFolderTheMachineRefusesAddsNoSection() async {
        let session = await loaded()
        await stub.fail(
            "workspace.create",
            code: "workspace-invalid-path",
            message: "cannot create a workspace at \"/code/nope\": path is not a directory"
        )

        let failure = await session.createWorkspace(path: "/code/nope")
        XCTAssertEqual(failure, "cannot create a workspace at \"/code/nope\": path is not a directory")
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        // Returned rather than banner-ed: this is done inside the folder sheet,
        // and the banner lives on the screen behind it.
        XCTAssertNil(session.problem)
    }

    // MARK: - Renaming

    func testRenamingSendsTheIdAndTheTitle() async {
        let session = await loaded()
        await stub.answer("workspace.rename", .object([
            "workspace": workspaceRow("w1", path: "/code/one", title: "Renamed", sessions: ["s1"]),
        ]))

        let renamed = await session.renameWorkspace("w1", title: "  Renamed  ")
        let sent = await stub.payloads("workspace.rename")

        XCTAssertTrue(renamed)
        // Trimmed here as well as on the machine, so what is drawn locally and
        // what is stored cannot disagree by a space.
        XCTAssertEqual(sent, [.object([
            "workspaceId": .string("w1"),
            "title": .string("Renamed"),
        ])])
        XCTAssertEqual(session.workspaces[0].displayTitle, "Renamed")
    }

    func testARefusedRenamePutsTheOldNameBackAndSaysWhy() async {
        let session = await loaded()
        await stub.fail(
            "workspace.rename",
            code: "workspace-name-conflict",
            message: "workspace name 'Two' is already in use"
        )

        let renamed = await session.renameWorkspace("w1", title: "Two")
        XCTAssertFalse(renamed)
        XCTAssertEqual(session.workspaces[0].displayTitle, "One")
        XCTAssertEqual(session.problem, "workspace name 'Two' is already in use")
    }

    /// Caught here rather than sent, so the empty case costs no round trip and
    /// says something better than a schema message would.
    func testABlankNameIsRefusedWithoutAskingTheMachine() async {
        let session = await loaded()
        let renamed = await session.renameWorkspace("w1", title: "   ")
        let attempts = await stub.count("workspace.rename")

        XCTAssertFalse(renamed)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(session.workspaces[0].displayTitle, "One")
        XCTAssertEqual(session.problem, "A workspace needs a name.")
    }

    // MARK: - Removing

    func testRemovingAWorkspaceSendsItsIdAndDropsTheSection() async {
        let session = await loaded()
        let removed = await session.deleteWorkspace("w1")
        let sent = await stub.payloads("workspace.delete")

        XCTAssertTrue(removed)
        XCTAssertEqual(sent, [.object(["workspaceId": .string("w1")])])
        XCTAssertTrue(session.workspaces.isEmpty)
    }

    /// The conversations are the point of the confirmation copy: removing a
    /// workspace removes the grouping and nothing else, so every row has to
    /// still be reachable afterwards.
    func testRemovingAWorkspaceKeepsItsConversations() async {
        let session = await loaded()
        _ = await session.deleteWorkspace("w1")

        let board = SessionBoard(sessions: session.sessions, workspaces: session.workspaces)
        XCTAssertEqual(Set(board.groups.flatMap { $0.sessions.map(\.id) }), ["s1", "stray"])
        XCTAssertEqual(board.groups.map(\.id), [SessionGroup.ungroupedId])
    }

    func testARefusedRemovalPutsTheSectionBack() async {
        let session = await loaded()
        await stub.fail("workspace.delete", code: "workspace-not-found", message: "workspace \"w1\" not found")

        let removed = await session.deleteWorkspace("w1")
        XCTAssertFalse(removed)
        XCTAssertEqual(session.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(session.workspaces[0].sessionIds, ["s1"], "the membership has to come back with it")
        XCTAssertEqual(session.problem, "workspace \"w1\" not found")
    }

    // MARK: - Starting a conversation in a workspace

    /// The folder goes out as `cwd`, never as `workspaceId`, and the grouping is
    /// a second call. A dsh new enough for `workspace.list` but not for
    /// `session.create {workspaceId}` would drop the unknown key and start the
    /// conversation in its own default directory — the wrong folder is a worse
    /// failure than the wrong section.
    func testStartingInAWorkspaceFolderSendsTheFolderThenJoins() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))

        let id = await session.createSession(cwd: "/code/one")
        let sent = await stub.payloads("session.create")

        XCTAssertEqual(id, "fresh")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, .object(["cwd": .string("/code/one")]))
        XCTAssertEqual(sent.last, .object([
            "sessionId": .string("fresh"),
            "workspaceId": .string("w1"),
        ]))
        XCTAssertNil(session.problem)
    }

    func testStartingInAnUnclaimedFolderMakesOnlyOneCall() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))

        _ = await session.createSession(cwd: "/code/two")
        let attempts = await stub.count("session.create")

        XCTAssertEqual(attempts, 1)
        XCTAssertNil(session.problem)
    }

    /// This used to raise "It's under Ungrouped", and that stopped being true:
    /// the board seats a conversation by its working directory whether or not
    /// the ledger write lands, so a failure here changes nothing this phone
    /// shows. Silence is only honest while that holds — which is what the
    /// board assertion pins.
    func testAConversationThatStartsButCannotJoinStaysSeatedAndSaysNothing() async {
        let session = await loaded()
        await stub.answer("session.create", .object(["sessionId": .string("fresh")]))
        await stub.fail("session.create", code: "workspace-attach-failed", message: "could not attach", after: 1)

        let id = await session.createSession(cwd: "/code/one")
        XCTAssertEqual(id, "fresh", "the conversation exists and is in the right folder")
        XCTAssertNil(session.problem, "an alert about the Mac's own bookkeeping interrupts nothing this phone got wrong")
        let board = SessionBoard(sessions: session.sessions, workspaces: session.workspaces)
        XCTAssertEqual(board.groups.first { $0.id == "w1" }?.sessions.first?.id, "fresh",
                       "the silence is only honest because the board seats it anyway")
    }

    // MARK: - Archiving

    /// `session.list` keeps answering with archived conversations, so marking
    /// rather than removing is what makes the archive survive a refresh. It did
    /// not, before: the row came back the next time the list was pulled.
    func testArchivingHidesTheConversationAndSurvivesARefresh() async {
        let session = await loaded()
        await session.archive(sessionId: "s1")
        let sent = await stub.payloads("workspace.archiveSession")

        XCTAssertEqual(session.archivedSessionIds, ["s1"])
        XCTAssertEqual(sent, [.object(["sessionId": .string("s1")])])

        // What the machine answers from here on. `session.list` keeps the row —
        // that is the point — and only the archive set says it should be gone.
        await stub.answer("workspace.list", .object([
            "items": .array([workspaceRow("w1", path: "/code/one", title: "One", sessions: ["s1"])]),
            "archivedSessionIds": .array([.string("s1")]),
        ]))
        await session.refreshSessions()
        XCTAssertTrue(session.sessions.contains { $0.id == "s1" }, "the machine still reports it")
        let board = SessionBoard(
            sessions: session.sessions,
            workspaces: session.workspaces,
            archived: session.archivedSessionIds
        )
        XCTAssertFalse(board.groups.flatMap { $0.sessions.map(\.id) }.contains("s1"))
    }

    func testARefusedArchiveBringsTheConversationBack() async {
        let session = await loaded()
        await stub.fail("workspace.archiveSession", code: "session-not-found", message: "session \"s1\" not found")

        await session.archive(sessionId: "s1")
        XCTAssertTrue(session.archivedSessionIds.isEmpty)
        XCTAssertEqual(session.problem, "session \"s1\" not found")
    }
}

/// Choosing a model, and the header agreeing that you did.
///
/// The write used to live in the picker sheet, which updated its own copy of
/// the catalogue and nothing else. `modelName` is otherwise set only from a
/// `request/header` event — which arrives when a turn *runs* — so the header
/// went on naming the previous model until the next message was sent. Reported
/// from a device: picked Flash, header still said Pro.
@MainActor
final class ModelSelectionTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var stub: StubTransport!

    override func setUp() {
        super.setUp()
        suiteName = "rowel.model.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        stub = StubTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func session() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", device: "device-1", key: "", token: "", name: "Test Mac"
        )
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: stub
        )
    }

    private let flash = ModelOption(
        provider: "deepseek", providerName: "DeepSeek",
        model: "deepseek-v4-flash", name: "DeepSeek V4 Flash (latest)", description: nil
    )

    func testTheHeaderFollowsTheChoiceWithoutWaitingForATurn() async {
        let machine = session()
        let conversation = machine.conversation("s1")
        conversation.setModel("DeepSeek V4 Pro (latest)")

        let failure = await machine.selectModel(sessionId: "s1", option: flash, effort: "high")

        XCTAssertNil(failure)
        XCTAssertEqual(conversation.modelName, "DeepSeek V4 Flash (latest)")
    }

    func testTheEffortRidesAlongWithTheModel() async {
        let machine = session()
        _ = await machine.selectModel(sessionId: "s1", option: flash, effort: "max")

        let sent = await stub.payloads("session.selectModel").last
        XCTAssertEqual(sent?["model"]?.stringValue, "deepseek-v4-flash")
        XCTAssertEqual(sent?["reasoningEffort"]?.stringValue, "max")
    }

    func testARefusedChoiceLeavesTheHeaderAlone() async {
        // The opposite failure to the one being fixed, and the reason the
        // update is applied on success rather than optimistically: a header
        // naming a model the machine rejected would be worse than a stale one.
        let machine = session()
        let conversation = machine.conversation("s1")
        conversation.setModel("DeepSeek V4 Pro (latest)")
        await stub.fail("session.selectModel", code: "model-unavailable", message: "No key for that provider.")

        let failure = await machine.selectModel(sessionId: "s1", option: flash, effort: nil)

        XCTAssertEqual(failure, "No key for that provider.")
        XCTAssertEqual(conversation.modelName, "DeepSeek V4 Pro (latest)")
    }
}

/// The machine's default access mode: what a conversation that does not exist
/// yet will start as.
///
/// This is the settings path (`settings.update {ns: permission, patch:
/// {defaultPreset}}`) and it is deliberately the *only* thing those writes
/// touch. It was drawn as a three-way picker inside the session panel and
/// reported as a dead control, because an existing session's `permissions`
/// projection does not move when the default changes — measured by changing the
/// default and running another turn. The conclusion drawn at the time, that a
/// session's mode is fixed at creation, was wrong: the mode of a running
/// conversation is changed by `/permission`, which is a different dsh call and
/// is covered by `SessionAccessTests` below.
@MainActor
final class AccessDefaultTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var stub: StubTransport!

    override func setUp() {
        super.setUp()
        suiteName = "rowel.access.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        stub = StubTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func settingsAnswer(_ preset: String, revision: Int = 3) -> JSONValue {
        .object(["namespaces": .array([
            .object([
                "ns": .string("permission"),
                "revision": .number(Double(revision)),
                "value": .object(["defaultPreset": .string(preset)]),
            ]),
        ])])
    }

    private func session() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", device: "device-1", key: "", token: "", name: "Test Mac"
        )
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: stub
        )
    }

    func testTheDefaultComesFromTheSettingNotASession() async {
        await stub.answer("settings.describe", settingsAnswer("read-only"))
        let machine = session()

        await machine.refreshAccessDefault()

        XCTAssertEqual(machine.accessDefault?.current, "read-only")
        XCTAssertEqual(machine.accessDefault?.options.count, 3)
    }

    func testChangingItSendsTheRevisionItRead() async {
        await stub.answer("settings.describe", settingsAnswer("workspace-write", revision: 7))
        let machine = session()
        await machine.refreshAccessDefault()

        _ = await machine.setPermission("danger-full-access")

        let sent = await stub.payloads("settings.update").last
        XCTAssertEqual(sent?.path("patch", "defaultPreset")?.stringValue, "danger-full-access")
        // Optimistic concurrency: a stale revision means somebody at the
        // keyboard changed it in between, and losing their change silently is
        // the worse outcome.
        XCTAssertEqual(sent?["expectedRevision"]?.intValue, 7)
    }

    func testTheChoiceShowsWithoutWaitingForAProjection() async {
        // The whole bug in one assertion. Nothing else updates this: the
        // per-session projection does not move for a settings change, so a UI
        // that waited for one would sit there looking broken.
        await stub.answer("settings.describe", settingsAnswer("workspace-write"))
        let machine = session()
        await machine.refreshAccessDefault()

        _ = await machine.setPermission("read-only")

        XCTAssertEqual(machine.accessDefault?.current, "read-only")
    }

    func testARefusalLeavesTheOldValueShowing() async {
        await stub.answer("settings.describe", settingsAnswer("workspace-write"))
        let machine = session()
        await machine.refreshAccessDefault()
        await stub.fail("settings.update", message: "Someone changed it first.")

        let failure = await machine.setPermission("danger-full-access")

        XCTAssertEqual(failure, "Someone changed it first.")
        XCTAssertEqual(machine.accessDefault?.current, "workspace-write")
    }
}

// MARK: - One conversation's access mode

/// Switching a running conversation, which is a different dsh call from the
/// machine default above and was believed to be impossible for a while.
///
/// The command is `/permission <preset>`, run through `commands/execute` rather
/// than typed into a prompt: a prompt carrying a `/`-prefixed line is not a
/// command at all — measured, it lands in the log as an ordinary user message
/// and starts a turn — so sending the words to the model is the failure this
/// route avoids. The payload shape asserted here is the one a real dsh accepted.
@MainActor
final class SessionAccessTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private var stub: StubTransport!

    override func setUp() {
        super.setUp()
        suiteName = "rowel.session.access.tests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        stub = StubTransport()
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// What the machine answers when it ran the command.
    private func ran(_ text: String) -> JSONValue {
        .object([
            "commandId": .string("cmd-1"),
            "result": .object(["kind": .string("success"), "text": .string(text)]),
        ])
    }

    private func projection(_ current: String) -> JSONValue {
        .object([
            "options": .array(["read-only", "workspace-write", "danger-full-access"].map {
                .object(["value": .string($0), "name": .string($0)])
            }),
            "currentValue": .string(current),
        ])
    }

    private func session() -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", device: "device-1", key: "", token: "", name: "Test Mac"
        )
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: suite,
            transport: stub
        )
    }

    func testTheSwitchIsThePermissionCommandForThatSession() async {
        await stub.answer("commands/execute", ran("preset read-only"))
        let machine = session()

        let failure = await machine.setSessionPermission(sessionId: "s1", preset: "read-only")

        XCTAssertNil(failure)
        let sent = await stub.payloads("commands/execute").last
        XCTAssertEqual(sent?.path("args", "agentId")?.stringValue, "s1")
        XCTAssertEqual(sent?.path("args", "line")?.stringValue, "/permission read-only")
        // A typert remote wants its arguments under exactly one `args` object,
        // and it wants the image list present even when empty — an absent key is
        // a strict-schema failure, not a default.
        XCTAssertEqual(sent?.path("args", "images")?.arrayValue?.isEmpty, true)
    }

    func testTheModeComesFromTheProjectionNotFromTheWrite() async {
        // The design decision worth pinning: this app never places the
        // checkmark itself. If it did, a session whose switch had not actually
        // taken effect would still show the new mode — and this particular lie
        // is about what the agent may do to someone's files.
        await stub.answer("commands/execute", ran("preset read-only"))
        let machine = session()
        let conversation = machine.conversation("s1")
        conversation.applyProjection(key: "permissions", value: projection("workspace-write"), seq: 4)

        _ = await machine.setSessionPermission(sessionId: "s1", preset: "read-only")

        XCTAssertEqual(conversation.permissions?.current, "workspace-write",
                       "the screen moved on its own, before the machine said so")

        conversation.applyProjection(key: "permissions", value: projection("read-only"), seq: 6)
        XCTAssertEqual(conversation.permissions?.current, "read-only")
    }

    func testAMacWithoutTheCommandSaysSoRatherThanPretending() async {
        // An older dsh has no `/permission`, and `commands/execute` answers a
        // bare `undefined` for a name it does not have. Reported as success
        // that would leave the person believing a mode had changed.
        let machine = session()

        let failure = await machine.setSessionPermission(sessionId: "s1", preset: "read-only")

        XCTAssertEqual(
            failure,
            "This Mac’s dsh has no /permission command, so a running conversation cannot be changed here."
        )
    }

    func testTheMachinesOwnWordsComeThroughWhenItRefuses() async {
        // The command exists and refused. Its message names the presets it does
        // have, which is more useful than anything this app could invent.
        let said = "unknown preset \"nonsense\" (available: read-only, workspace-write, danger-full-access)"
        await stub.answer("commands/execute", .object([
            "commandId": .string("cmd-2"),
            "result": .object(["kind": .string("error"), "text": .string(said)]),
        ]))
        let machine = session()

        let failure = await machine.setSessionPermission(sessionId: "s1", preset: "nonsense")

        XCTAssertEqual(failure, said)
    }

    func testATunnelThatCannotCarryItSaysSo() async {
        await stub.fail("commands/execute", message: "the Mac is unreachable")
        let machine = session()

        let failure = await machine.setSessionPermission(sessionId: "s1", preset: "read-only")

        XCTAssertEqual(failure, "the Mac is unreachable")
    }
}

// MARK: - Archiving

/// Archiving is optimistic, which is only safe if the undo is real — and this
/// undo had never been run. Noted as a gap when the row-level tests were
/// written and left open until the transport seam existed; the swipe action
/// that reaches it shipped before the test did.
final class ArchiveTests: XCTestCase {
    func testTheRowGoesBeforeTheMachineAnswers() async {
        let stub = StubTransport()
        let session = await make(stub)
        await session.archive(sessionId: "s1")

        let hidden = await MainActor.run { session.archivedSessionIds.contains("s1") }
        XCTAssertTrue(hidden, "a row that lingers for a round trip reads as a tap that missed")
        let sent = await stub.payloads("workspace.archiveSession").first
        XCTAssertEqual(sent?["sessionId"]?.stringValue, "s1")
    }

    func testARefusalPutsTheRowBackAndSaysSo() async {
        let stub = StubTransport()
        await stub.fail("workspace.archiveSession", message: "the Mac said no")
        let session = await make(stub)
        await session.archive(sessionId: "s1")

        let state = await MainActor.run { (session.archivedSessionIds, session.problem) }
        XCTAssertFalse(state.0.contains("s1"), "the conversation stayed hidden after the machine refused")
        XCTAssertEqual(state.1, "the Mac said no", "it vanished silently, which reads as success")
    }

    @MainActor
    private func make(_ stub: StubTransport) -> MachineSession {
        let bundle = PairingBundle(
            relay: "https://relay.invalid", direct: nil, device: "device-1",
            key: "", token: "", name: "Test Mac"
        )
        return MachineSession(
            machine: PairedMachine(bundle: bundle),
            identity: .generate(),
            deviceName: "Test iPhone",
            clientVersion: "rowel-tests/1",
            pairingToken: nil,
            notifier: Notifier(center: nil),
            defaults: UserDefaults(suiteName: "archive-tests-\(UUID().uuidString)")!,
            transport: stub
        )
    }
}
