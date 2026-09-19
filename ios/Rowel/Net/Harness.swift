/// Typed calls into the harness.
///
/// A thin layer over `Tunnel.call`, and deliberately thin: the harness's own
/// contract is JSON, its vocabulary grows with whatever plugins a person has
/// mounted, and a Swift mirror of every payload would be stale the first time
/// someone installs one. What is worth typing is the two dozen methods this app
/// actually invokes, so a typo becomes a compile error instead of a runtime
/// `method-not-found`.

import Foundation

/// The one thing `Harness` needs from the world: a way to invoke a method and a
/// way to answer a request the machine made.
///
/// A protocol rather than the concrete `Tunnel` for one reason — the write paths
/// in `MachineSession` are mostly *failure* handling, and a rollback that has
/// never been run is a rollback nobody has checked. Tests hand in a transport
/// that fails on demand; the app hands in the tunnel and nothing else changes.
public protocol HarnessTransport: Sendable {
    @discardableResult
    func call(_ method: String, _ payload: JSONValue) async throws -> JSONValue
    @discardableResult
    func respond(rpcId: String, value: JSONValue) async throws -> JSONValue
}

extension Tunnel: HarnessTransport {}

public struct Harness: Sendable {
    let transport: any HarnessTransport

    public init(tunnel: Tunnel) {
        transport = tunnel
    }

    public init(transport: any HarnessTransport) {
        self.transport = transport
    }

    // MARK: - Machine

    /// Version, working directory, and current model of the machine.
    public func describe() async throws -> JSONValue {
        try await transport.call("host.describe", .emptyObject)
    }

    /// Browse the machine's filesystem for a folder to start a conversation in.
    public func listDirectory(path: String?) async throws -> DirectoryListing {
        let value = try await transport.call("host.listDirectory", .object(dropping: ["path": path.map(JSONValue.string)]))
        return DirectoryListing(
            path: value["path"]?.stringValue ?? "/",
            home: value["home"]?.stringValue ?? "/",
            crumbs: Harness.entries(value["crumbs"]),
            entries: Harness.entries(value["entries"]),
            truncated: value["truncated"]?.boolValue ?? false
        )
    }

    private static func entries(_ value: JSONValue?) -> [DirectoryEntry] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let path = entry["path"]?.stringValue else { return nil }
            return DirectoryEntry(
                name: entry["name"]?.stringValue ?? (path as NSString).lastPathComponent,
                path: path,
                hidden: entry["hidden"]?.boolValue ?? false
            )
        }
    }

    // MARK: - Sessions

    /// Every persisted conversation, newest first.
    public func listSessions() async throws -> [SessionSummary] {
        let value = try await transport.call("session.list", .emptyObject)
        return (value["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
    }

    /// The machine's sidebar groups, which conversations are in each, and which
    /// conversations have been filed away.
    ///
    /// A second call rather than a field on the session rows, because that is
    /// how the machine holds it: membership belongs to the workspace. The list
    /// screen joins the two.
    ///
    /// The archive set comes back here rather than from `session.list`, which
    /// does not filter it — the machine treats hiding an archived conversation
    /// as the client's job, and this is the only call that says which they are.
    ///
    /// Throws on a dsh that predates workspaces. Not with a code worth matching
    /// on, unfortunately: the route simply does not exist, the Bridle sees an
    /// HTTP 404 and reports `internal`, which is indistinguishable from a real
    /// fault. So the caller treats *any* failure as "cannot say" and only ever
    /// concludes that a machine groups from a call that succeeded.
    public func listWorkspaces() async throws -> (items: [Workspace], archived: Set<String>) {
        let value = try await transport.call("workspace.list", .emptyObject)
        let archived = (value["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
        return ((value["items"]?.arrayValue ?? []).compactMap(Workspace.init), Set(archived))
    }

    // MARK: - Rearranging the sidebar
    //
    // Five of the machine's seven `workspace.*` methods; the two missing ones
    // are missing on purpose.
    //
    // `workspace.insertBefore {workspaceId, beforeWorkspaceId?}` moves a
    // workspace within the Mac's own sidebar order. This app sorts its sections
    // by what was touched most recently instead — see `SessionBoard` — so
    // calling it would write a durable change to the Mac that has no effect on
    // any screen here.
    //
    // `workspace.insertSessionBefore {workspaceId, sessionId, beforeSessionId?}`
    // reorders a conversation *inside* the workspace that already holds it. Two
    // reasons it is not wired up: the same one — group members are sorted by
    // activity here, so the manual order is invisible — and the more important
    // one, that it cannot move anything between workspaces. The machine refuses
    // a session the named workspace does not already account for
    // (`workspace-move-invalid`), because membership is not a free choice: a
    // workspace stands for a directory, and a conversation belongs to it only
    // when its own working directory *is* that directory. There is no reparent
    // to offer.

    /// Adopt an existing directory as a workspace.
    ///
    /// Nothing is created on disk — the machine refuses a path that is not
    /// already a directory. Asking twice for the same folder is not an error and
    /// not a duplicate: the second call answers with the workspace that is
    /// already there.
    ///
    /// The new workspace starts empty. It does not sweep up the conversations
    /// that already run in that folder, and no call exposed to this app can;
    /// what it does is claim the folder, so that conversations started in it
    /// from here on are filed there.
    ///
    /// - Returns: the workspace, and whether this call is what made it.
    public func createWorkspace(path: String) async throws -> (workspace: Workspace, created: Bool) {
        let value = try await transport.call("workspace.create", .object(["path": .string(path)]))
        guard let made = value["workspace"].flatMap(Workspace.init) else {
            throw CallError(code: "internal", message: "The Mac made a workspace but didn’t say which.")
        }
        return (made, value["created"]?.boolValue ?? true)
    }

    /// Rename a workspace.
    ///
    /// The machine trims the title, refuses a blank one, and refuses a title
    /// another workspace already carries (`workspace-name-conflict`). Its
    /// message for that names the clash, so it is worth showing verbatim.
    public func renameWorkspace(id: String, title: String) async throws -> Workspace {
        let value = try await transport.call("workspace.rename", .object([
            "workspaceId": .string(id),
            "title": .string(title),
        ]))
        guard let renamed = value["workspace"].flatMap(Workspace.init) else {
            throw CallError(code: "internal", message: "The Mac renamed the workspace but didn’t say what to.")
        }
        return renamed
    }

    /// Remove a workspace registration.
    ///
    /// Only the grouping. The directory, the files in it, and every one of the
    /// conversations it held survive untouched — they stop being grouped and
    /// nothing else. Verified against the machine's own contract, which is
    /// explicit that deletion "never substitutes" for removing a folder or a
    /// session, and that the sessions "consequently become ungrouped".
    ///
    /// Not reversible from here, though, and that is the part worth a
    /// confirmation: re-registering the same folder mints a fresh workspace that
    /// does not re-adopt anything, so the grouping itself is gone for good.
    public func deleteWorkspace(id: String) async throws {
        try await transport.call("workspace.delete", .object(["workspaceId": .string(id)]))
    }

    /// Write a just-created conversation into its workspace's ledger.
    ///
    /// There is no `workspace.attachSession` on the wire. What there is, is
    /// `session.create` being idempotent for an id that already exists: given
    /// both a `sessionId` and a `workspaceId` the machine resolves the session
    /// it already has and then attaches it, which is the same code path a
    /// conversation created *into* a workspace takes.
    ///
    /// Only ever called for a conversation this app created moments ago — the
    /// idempotent re-create would otherwise resume a cold session into memory
    /// as a side effect, which is why no bulk backfill of old conversations
    /// goes through here. Grouping on the phone does not depend on this write:
    /// `SessionBoard` seats a conversation by its working directory either
    /// way. This keeps the Mac's own sidebar in step, nothing more.
    public func fileSession(_ sessionId: String, into workspaceId: String) async throws {
        try await transport.call("session.create", .object([
            "sessionId": .string(sessionId),
            "workspaceId": .string(workspaceId),
        ]))
    }

    /// One page of a session's event log. Omit `beforeSeq` for the tail.
    public func history(sessionId: String, beforeSeq: Int? = nil, maxMessages: Int? = nil) async throws -> JSONValue {
        try await transport.call("session.history", .object(dropping: [
            "sessionId": .string(sessionId),
            "beforeSeq": beforeSeq.map { JSONValue.number(Double($0)) },
            "maxMessages": maxMessages.map { JSONValue.number(Double($0)) },
        ]))
    }

    /// The agent presets this machine can start a conversation as.
    public func presets() async throws -> [AgentPreset] {
        let value = try await transport.call("agentPreset.list", .emptyObject)
        return (value["presets"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["id"]?.stringValue else { return nil }
            return AgentPreset(
                id: id,
                name: entry["name"]?.stringValue ?? id,
                detail: entry["description"]?.stringValue ?? "",
                isDefault: entry["isDefault"]?.boolValue ?? false
            )
        }
    }

    /// Every plugin mounted in the machine's dsh, running or not.
    ///
    /// The payload envelope differs from every other method here: this is a
    /// cordis remote event rather than a typert method, and that transport
    /// wants its arguments wrapped in exactly one `args` object. Measured — a
    /// bare `{}` is answered with "Remote payload must contain exactly one
    /// plain-object args field".
    public func pluginInventory() async throws -> [PluginEntry] {
        let value = try await transport.call("pluginInventory/list", .object(["args": .emptyObject]))
        return (value["entries"]?.arrayValue ?? []).compactMap { entry in
            guard let id = entry["entryId"]?.stringValue else { return nil }
            return PluginEntry(
                id: id,
                module: entry["moduleName"]?.stringValue ?? id,
                enabled: entry["enabled"]?.boolValue ?? false,
                phase: entry["fiberPhase"]?.stringValue
            )
        }
    }

    /// Start a conversation in a folder.
    public func createSession(cwd: String?, agentPreset: String? = nil) async throws -> String {
        let value = try await transport.call("session.create", .object(dropping: [
            "cwd": cwd.map(JSONValue.string),
            "agentPreset": agentPreset.map(JSONValue.string),
        ]))
        guard let id = value["sessionId"]?.stringValue else {
            throw CallError(code: "internal", message: "The Mac created a conversation but didn’t say which.")
        }
        return id
    }

    /// Send a message.
    ///
    /// `steer` interrupts the running turn with the new instruction; `queue`
    /// waits for the current one to finish. The app picks `steer` when a turn is
    /// running because that is what a person tapping send mid-answer means.
    public func prompt(sessionId: String, text: String, images: [PromptImage] = [], steer: Bool) async throws {
        var content: [JSONValue] = []
        if !text.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(text)]))
        }
        for image in images {
            content.append(.object(dropping: [
                "type": .string("image"),
                "mediaType": .string(image.mediaType),
                "data": .string(image.base64),
                "name": image.name.map(JSONValue.string),
            ]))
        }
        try await transport.call("session.prompt", .object([
            "sessionId": .string(sessionId),
            "mode": .string(steer ? "steer" : "queue"),
            "content": .array(content),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ]))
    }

    /// Stop the running turn.
    public func cancel(sessionId: String) async throws {
        try await transport.call("session.cancel", .object(["sessionId": .string(sessionId)]))
    }

    /// Run one slash command against a session. Nothing reaches the model.
    ///
    /// `commands/execute`, because a `session.prompt` carrying the command line
    /// does **not** run a command: measured on a scratch session, a prompt whose
    /// text was `/permission` turned up in the log as an ordinary `user/message`
    /// and started a turn, with the model left to work out what the words meant.
    /// Command dispatch is the client's job in dsh — the browser's composer
    /// recognises the leading slash and calls this same method — so the second
    /// reason this is the right call is what it answers for a name the machine
    /// does not have: `undefined`, before anything is admitted, which lets the
    /// caller say "this Mac cannot do that" instead of guessing.
    ///
    /// A Typert remote method, so its arguments live under one `args` object —
    /// the same envelope as `pluginInventory/list`, and for the same reason.
    ///
    /// - Returns: what the command said, or nil when the machine has no such
    ///   command (an older dsh, or a plugin that is not mounted).
    public func command(sessionId: String, line: String) async throws -> String? {
        let value = try await transport.call("commands/execute", .object([
            "args": .object([
                "agentId": .string(sessionId),
                "line": .string(line),
                "images": .array([]),
            ]),
        ]))
        guard let result = value["result"] else { return nil }
        let said = result["text"]?.stringValue
        if result["kind"]?.stringValue == "error" {
            // The command ran and refused, which is a different outcome from
            // not being there at all. Its own words name the reason — an
            // unknown preset lists the ones the machine has — so they go
            // through untouched.
            throw CallError(code: "command-error", message: said ?? "The Mac refused that command.")
        }
        return said ?? ""
    }

    /// Branch a conversation, keeping its history up to now.
    ///
    /// - Returns: the new session's id.
    public func fork(sessionId: String) async throws -> String {
        let value = try await transport.call("session.fork", .object(["sessionId": .string(sessionId)]))
        guard let id = value["sessionId"]?.stringValue else {
            throw CallError(code: "internal", message: "The Mac branched the conversation but didn’t say where to.")
        }
        return id
    }

    /// Take a conversation out of the list without destroying it.
    ///
    /// A `workspace` method rather than a `session` one, because on this
    /// machine archiving is a sidebar operation; the session itself is intact
    /// and the Mac can bring it back.
    public func archive(sessionId: String) async throws {
        try await transport.call("workspace.archiveSession", .object(["sessionId": .string(sessionId)]))
    }

    /// What new conversations on this machine will start as, and the choices.
    ///
    /// Read from the setting rather than from a session's `permissions`
    /// projection: that projection reports what *that* conversation is running
    /// under, which is fixed at its creation and so answers a different
    /// question. This one is about conversations that do not exist yet.
    public func permissionDefault() async throws -> PermissionChoice? {
        let described = try await transport.call("settings.describe", .emptyObject)
        let namespace = (described["namespaces"]?.arrayValue ?? [])
            .first { $0["ns"]?.stringValue == "permission" }
        guard let current = namespace?.path("value", "defaultPreset")?.stringValue else { return nil }
        // The setting carries the value; the schema carries the choices, and
        // reading them out of a compiled schema is not worth it. These three
        // are the union dsh declares and it has no per-machine variation.
        return PermissionChoice(.object([
            "currentValue": .string(current),
            "options": .array(["read-only", "workspace-write", "danger-full-access"].map {
                .object(["value": .string($0), "name": .string($0)])
            }),
        ]))
    }

    /// Change how much the agent is allowed to touch.
    ///
    /// Two calls, because the machine uses optimistic concurrency: read the
    /// namespace's revision, then send the patch against it. Passing a stale
    /// revision is refused rather than silently overwriting whoever changed it
    /// in between — which on this machine is most likely the person sitting at
    /// it, and losing their change would be the worse outcome.
    ///
    /// A machine-wide default, and only that: `permission` is one namespace with
    /// one value, and the value is the mode a conversation that does not exist
    /// yet will start in. Changing a conversation that is already running is
    /// `command(sessionId:line:)` with `/permission` — a different call against
    /// a different thing, and the one this doc comment used to deny existed.
    public func setPermission(_ preset: String) async throws {
        let described = try await transport.call("settings.describe", .emptyObject)
        let revision = (described["namespaces"]?.arrayValue ?? [])
            .first { $0["ns"]?.stringValue == "permission" }?["revision"]?.intValue
        var payload: [String: JSONValue] = [
            "ns": .string("permission"),
            "patch": .object(["defaultPreset": .string(preset)]),
        ]
        if let revision { payload["expectedRevision"] = .number(Double(revision)) }
        try await transport.call("settings.update", .object(payload))
    }

    /// Set a session's title by hand.
    public func rename(sessionId: String, title: String) async throws {
        try await transport.call("session.rename", .object([
            "sessionId": .string(sessionId),
            "title": .string(title),
        ]))
    }

    /// Search the message surface across conversations.
    ///
    /// The machine answers with ids and excerpts, not summaries — titles and
    /// timestamps stay owned by `session.list` — so the caller joins the hits
    /// against the list it already holds.
    public func search(query: String) async throws -> (hits: [SearchHit], hasMore: Bool) {
        let value = try await transport.call("session.search", .object(["query": .string(query)]))
        let hits = (value["items"]?.arrayValue ?? []).compactMap { item -> SearchHit? in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            return SearchHit(id: id, snippet: item["snippet"]?.stringValue ?? "")
        }
        return (hits, value["hasMore"]?.boolValue ?? false)
    }

    /// Remove or promote one queued message.
    public func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
        var payload: JSONValue = .object(["kind": .string(action.kind)])
        if case .edit(let text) = action {
            payload = .object([
                "kind": .string("edit"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])
        }
        try await transport.call("session.updateQueue", .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
            "action": payload,
        ]))
    }

    /// Fetch one image referenced by a message, as base64.
    public func attachment(sessionId: String, attachmentId: String) async throws -> (mediaType: String, base64: String) {
        let value = try await transport.call("session.attachment", .object([
            "sessionId": .string(sessionId),
            "attachmentId": .string(attachmentId),
        ]))
        return (
            value.path("attachment", "mediaType")?.stringValue ?? "image/png",
            value["data"]?.stringValue ?? ""
        )
    }

    /// The children this session spawned.
    ///
    /// `parentAvailable` comes back false when the machine cannot enumerate —
    /// it is not the same as "no children", and the UI has to be able to tell
    /// "nothing spawned anything" from "cannot say".
    public func subagents(parentSessionId: String) async throws -> (children: [SubagentChild], available: Bool) {
        let value = try await transport.call("subagent.list", .object(["parentSessionId": .string(parentSessionId)]))
        let children = (value["entries"]?.arrayValue ?? []).compactMap { SubagentChild($0) }
        return (children, value["parentAvailable"]?.boolValue ?? false)
    }

    /// The slash commands available in a session.
    ///
    /// Per session rather than per machine: skills can be scoped, and asking
    /// the machine in general would offer names that turn out not to work here.
    public func skills(sessionId: String) async throws -> [SkillCommand] {
        let value = try await transport.call("skill.list", .object(["sessionId": .string(sessionId)]))
        return (value["skills"]?.arrayValue ?? []).compactMap(SkillCommand.init)
    }

    // MARK: - Models

    /// The models this session can switch to.
    public func models(sessionId: String) async throws -> ModelCatalog {
        Harness.catalog(try await transport.call("session.models", .object(["sessionId": .string(sessionId)])))
    }

    /// Every model the machine can route to, independent of any session.
    ///
    /// `session.models` needs a session to ask about, which is the wrong shape
    /// for choosing what a session that does not exist yet should start on.
    public func machineModels() async throws -> ModelCatalog {
        Harness.catalog(try await transport.call("llm.models", .emptyObject))
    }

    /// Both calls answer with the same `groups → models` shape.
    static func catalog(_ value: JSONValue) -> ModelCatalog {
        var options: [ModelOption] = []
        var efforts: [String: [ReasoningEffort]] = [:]
        var defaultEfforts: [String: String] = [:]
        for group in value["groups"]?.arrayValue ?? [] {
            let provider = group["id"]?.stringValue ?? ""
            let providerName = group["name"]?.stringValue ?? provider
            for model in group["models"]?.arrayValue ?? [] {
                guard let id = model["id"]?.stringValue else { continue }
                let option = ModelOption(
                    provider: provider,
                    providerName: providerName,
                    model: id,
                    name: model["name"]?.stringValue ?? id,
                    description: model["description"]?.stringValue
                )
                options.append(option)
                // Absent for models that do not reason on demand, which is why
                // the picker keys off "is this list empty" rather than a flag.
                let levels = (model.path("reasoning", "efforts")?.arrayValue ?? []).compactMap { entry -> ReasoningEffort? in
                    guard let id = entry["id"]?.stringValue else { return nil }
                    return ReasoningEffort(id: id, name: entry["name"]?.stringValue ?? id)
                }
                if !levels.isEmpty {
                    efforts[option.id] = levels
                    defaultEfforts[option.id] = model.path("reasoning", "defaultEffort")?.stringValue
                }
            }
        }
        let currentProvider = value.path("current", "provider")?.stringValue
        let currentModel = value.path("current", "model")?.stringValue
        let current = options.first { $0.provider == currentProvider && $0.model == currentModel }
            ?? currentModel.map {
                ModelOption(
                    provider: currentProvider ?? "",
                    providerName: currentProvider ?? "",
                    model: $0,
                    name: $0,
                    description: nil
                )
            }
        let failures = (value["failures"]?.arrayValue ?? []).map { failure in
            let name = failure["name"]?.stringValue ?? failure["id"]?.stringValue ?? "a provider"
            return "\(name): \(failure["message"]?.stringValue ?? "could not be reached")"
        }
        return ModelCatalog(
            current: current,
            options: options,
            failures: failures,
            efforts: efforts,
            defaultEfforts: defaultEfforts,
            currentEffort: value.path("current", "reasoningEffort")?.stringValue
        )
    }

    /// Switch this session's model.
    public func selectModel(sessionId: String, option: ModelOption, reasoningEffort: String? = nil) async throws {
        try await transport.call("session.selectModel", .object(dropping: [
            "sessionId": .string(sessionId),
            "provider": .string(option.provider),
            "model": .string(option.model),
            "reasoningEffort": reasoningEffort.map(JSONValue.string),
        ]))
    }

    // MARK: - Answering the agent

    /// Allow or refuse one tool call.
    public func answerApproval(_ request: ApprovalRequest, allow: Bool) async throws {
        try await transport.respond(rpcId: request.id, value: .object([
            "sessionId": .string(request.sessionId),
            "approvalId": .string(request.approvalId),
            "outcome": .string(allow ? "allowed-once" : "rejected"),
        ]))
    }

    /// Answer one batch of questions.
    public func answerQuestion(_ request: QuestionRequest, answers: [String: QuestionAnswer]) async throws {
        let payload = request.items.map { item -> JSONValue in
            let answer = answers[item.id]
            return .object(dropping: [
                "id": .string(item.id),
                "selected": .array((answer?.selected ?? []).map(JSONValue.string)),
                "custom": answer?.custom.map(JSONValue.string),
            ])
        }
        try await transport.respond(rpcId: request.id, value: .object([
            "sessionId": .string(request.sessionId),
            "answer": .object(["answers": .array(payload)]),
        ]))
    }
}

/// What to do with a message the agent has not claimed yet.
/// One way this machine can behave when a conversation starts.
public struct AgentPreset: Identifiable, Equatable, Sendable {
    public let id: String
    /// Display name, in whatever language the machine speaks.
    public let name: String
    public let detail: String
    /// What a conversation gets when nobody chooses.
    public let isDefault: Bool
}

/// One plugin mounted in the machine's dsh.
public struct PluginEntry: Identifiable, Equatable, Sendable {
    public let id: String
    /// Package name, the most recognisable thing about it.
    public let module: String
    public let enabled: Bool
    /// Lifecycle state when enabled — `active`, `pending`, or absent.
    public let phase: String?
}

public enum QueueAction: Equatable, Sendable {
    case edit(String)
    case remove
    case steer

    var kind: String {
        switch self {
        case .edit: return "edit"
        case .remove: return "remove"
        case .steer: return "steer"
        }
    }
}

/// One conversation the search matched, and where.
public struct SearchHit: Identifiable, Equatable, Sendable {
    public var id: String
    public var snippet: String
}

/// An image being sent with a prompt.
public struct PromptImage: Sendable, Equatable {
    public var mediaType: String
    public var base64: String
    public var name: String?

    public init(mediaType: String, base64: String, name: String?) {
        self.mediaType = mediaType
        self.base64 = base64
        self.name = name
    }
}

/// What the person picked for one question.
public struct QuestionAnswer: Equatable {
    public var selected: [String]
    public var custom: String?

    public init(selected: [String] = [], custom: String? = nil) {
        self.selected = selected
        self.custom = custom
    }
}
