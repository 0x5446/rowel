/// Typed calls into dsh, through the Bridle.
///
/// A thin layer over `Tunnel.call` and `Tunnel.open`, and deliberately thin:
/// tunnel version 2 carries dsh 0.2's own API unchanged (docs/protocol.md §4),
/// its vocabulary grows with whatever plugins a person has mounted, and a Swift
/// mirror of every payload would be stale the first time someone installs one.
/// What is worth typing is the endpoints this app actually uses, so a typo
/// becomes a compile error instead of a runtime `gateway/not-found`.
///
/// dsh checks argument names exactly — one too many or too few is
/// `gateway/arguments-invalid` — and the shapes here were written against what
/// a real dsh 0.2 answers: `e2e/scripts/capture-fixtures.mjs` records it into
/// `RowelTests/Fixtures/dsh-0.2/`, and the tests decode those files.

import Foundation

/// The one thing `Harness` needs from the world: a way to call an endpoint and
/// a way to open a stream.
///
/// A protocol rather than the concrete `Tunnel` for one reason — the write paths
/// in `MachineSession` are mostly *failure* handling, and a rollback that has
/// never been run is a rollback nobody has checked. Tests hand in a transport
/// that fails on demand; the app hands in the tunnel and nothing else changes.
public protocol HarnessTransport: Sendable {
    @discardableResult
    func call(_ endpoint: String, _ args: JSONValue) async throws -> JSONValue
    func open(_ endpoint: String, _ args: JSONValue) async -> TunnelStream
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

    /// Browse the machine's filesystem for a folder to start a conversation in.
    ///
    /// dsh 0.2 answers this only when its profile composes the browsing picker
    /// (`@deepseek-ai/dsh-host-directory-picker-browse`); the default web profile
    /// serves the native one and answers `directory-picker/unavailable`.
    public func listDirectory(path: String?) async throws -> DirectoryListing {
        let value = try await transport.call("directoryPicker/list", .object(dropping: ["path": path.map(JSONValue.string)]))
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

    // MARK: - Machine-wide streams

    /// Approvals and questions waiting on a person, and what changes in the
    /// session list. The first item is `ready`, carrying the `clientId` every
    /// answer from this stream must name. See docs/dsh-0.2-protocol.md §5.
    public func events() async -> TunnelStream {
        await transport.open("$events", .emptyObject)
    }

    /// The machine's workspaces and its archived set: a `baseline`, then
    /// changes. Reopened after every reconnect, which always starts with a
    /// fresh baseline.
    public func followWorkspaces() async -> TunnelStream {
        await transport.open("workspace/follow", .emptyObject)
    }

    /// Projection changes for every session dsh has loaded: a `baseline`, then
    /// one `projection` item per key that changes.
    public func followControl() async -> TunnelStream {
        await transport.open("session/control", .emptyObject)
    }

    // MARK: - Sessions

    /// Every persisted conversation, subagents included.
    public func listSessions() async throws -> [SessionSummary] {
        let value = try await transport.call("session/list", .object(["_request": .emptyObject]))
        return (value["items"]?.arrayValue ?? []).compactMap(SessionSummary.init)
    }

    /// Follow one conversation: a snapshot of its tail page, then every event,
    /// and — with `assistantStream` — the model's output as it is written.
    ///
    /// dsh cannot resume a follow from a position: every open answers with a
    /// fresh snapshot, which the caller swaps in for what it held.
    public func follow(sessionId: String, maxMessages: Int) async -> TunnelStream {
        await transport.open("session/follow", .object(["request": .object([
            "address": Harness.address(sessionId),
            "assistantStream": .bool(true),
            "maxMessages": .number(Double(maxMessages)),
        ])]))
    }

    /// One page of a conversation's log, older than `beforeSeq`.
    /// - Parameter throughSeq: the cursor of the snapshot being paged back
    ///   from, which pins the page to the same log the snapshot read.
    public func page(sessionId: String, throughSeq: Int, beforeSeq: Int?, maxMessages: Int) async throws -> JSONValue {
        try await transport.call("session/page", .object(["request": .object(dropping: [
            "address": Harness.address(sessionId),
            "throughSeq": .number(Double(throughSeq)),
            "beforeSeq": beforeSeq.map { JSONValue.number(Double($0)) },
            "maxMessages": .number(Double(maxMessages)),
        ])]))
    }

    /// Where a conversation lives, in dsh's terms.
    static func address(_ sessionId: String) -> JSONValue {
        .object(["kind": .string("session"), "sessionId": .string(sessionId)])
    }

    // MARK: - Rearranging the sidebar
    //
    // Five of dsh's `workspace/*` endpoints. The two reordering ones are left
    // out on purpose: this app sorts by what was touched most recently, so a
    // manual order written to the Mac would change nothing on any screen here,
    // and a conversation belongs to the workspace whose path is its working
    // directory — there is no moving it between workspaces to offer.

    /// Adopt an existing directory as a workspace. Asking twice for the same
    /// folder answers with the workspace already there.
    ///
    /// - Returns: the workspace, and whether this call is what made it.
    public func createWorkspace(path: String) async throws -> (workspace: Workspace, created: Bool) {
        let value = try await transport.call("workspace/create", .object(["request": .object(["path": .string(path)])]))
        guard let made = value["workspace"].flatMap(Workspace.init) else {
            throw CallError(code: "internal", message: "The Mac made a workspace but didn’t say which.")
        }
        return (made, value["created"]?.boolValue ?? true)
    }

    /// Rename a workspace. A title another workspace carries is refused with
    /// `workspace-name-conflict`, whose message is worth showing verbatim.
    public func renameWorkspace(id: String, title: String) async throws -> Workspace {
        let value = try await transport.call("workspace/rename", .object(["request": .object([
            "workspaceId": .string(id),
            "title": .string(title),
        ])]))
        guard let renamed = value["workspace"].flatMap(Workspace.init) else {
            throw CallError(code: "internal", message: "The Mac renamed the workspace but didn’t say what to.")
        }
        return renamed
    }

    /// Remove a workspace registration — only the grouping. The directory, its
    /// files and every conversation it held survive; they stop being grouped.
    public func deleteWorkspace(id: String) async throws {
        try await transport.call("workspace/delete", .object(["request": .object(["workspaceId": .string(id)])]))
    }

    /// Write a just-created conversation into its workspace's ledger.
    ///
    /// `session/create` is idempotent for an id that already exists: given both
    /// a `sessionId` and a `workspaceId` dsh resolves the session it has and
    /// attaches it. Only for a conversation created moments ago — the re-create
    /// would otherwise load a cold session as a side effect.
    public func fileSession(_ sessionId: String, into workspaceId: String) async throws {
        try await transport.call("session/create", .object(["request": .object([
            "sessionId": .string(sessionId),
            "workspaceId": .string(workspaceId),
        ])]))
    }

    /// The agent presets this machine can start a conversation as. dsh 0.2
    /// names them only by id.
    public func presets() async throws -> [AgentPreset] {
        let value = try await transport.call("agentPresets/list", .emptyObject)
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
    public func pluginInventory() async throws -> [PluginEntry] {
        let value = try await transport.call("pluginInventory/list", .emptyObject)
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

    /// Start a conversation, in a folder or a workspace.
    public func createSession(cwd: String?, workspaceId: String? = nil, agentPreset: String? = nil) async throws -> String {
        let value = try await transport.call("session/create", .object(["request": .object(dropping: [
            "cwd": cwd.map(JSONValue.string),
            "workspaceId": workspaceId.map(JSONValue.string),
            "agentPreset": agentPreset.map(JSONValue.string),
        ])]))
        guard let id = value["sessionId"]?.stringValue else {
            throw CallError(code: "internal", message: "The Mac created a conversation but didn’t say which.")
        }
        return id
    }

    /// Send a message.
    ///
    /// - Parameters:
    ///   - requestId: names this message for good. dsh logs it on the message
    ///     (`source.rpcId`), which is how the copy shown before the machine
    ///     answered is matched to the real one. dsh also ignores a second send
    ///     under the same id — but not in the moment between a turn claiming
    ///     the message and logging it (docs/dsh-0.2-protocol.md §7.1), so a
    ///     send whose answer was lost is checked against the log, not resent.
    ///   - steer: interrupt the running turn; otherwise queue behind it.
    public func prompt(sessionId: String, requestId: String, text: String, images: [PromptImage] = [], steer: Bool) async throws {
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
        try await transport.call("session/prompt", .object(["request": .object([
            "requestId": .string(requestId),
            "sessionId": .string(sessionId),
            "mode": .string(steer ? "steer" : "queue"),
            "content": .array(content),
            "clientTimeZone": .string(TimeZone.current.identifier),
        ])]))
    }

    /// Stop the running turn.
    public func cancel(sessionId: String) async throws {
        try await transport.call("session/cancel", .object(["request": .object(["sessionId": .string(sessionId)])]))
    }

    /// Run one slash command against a session. Nothing reaches the model.
    ///
    /// `commands/execute`, because `session/prompt` does not parse commands: a
    /// prompt whose text is `/permission` lands in the log as words and starts a
    /// turn. Command dispatch is the client's job — the browser's composer
    /// calls this same endpoint.
    ///
    /// - Returns: what the command said, or nil when the machine answered with
    ///   no result (no such command mounted).
    public func command(sessionId: String, line: String) async throws -> String? {
        let value = try await transport.call("commands/execute", .object([
            "agentId": .string(sessionId),
            "line": .string(line),
            "submittedAttachments": .array([]),
        ]))
        guard let result = value["result"] else { return nil }
        let said = result["text"]?.stringValue
        if result["kind"]?.stringValue == "error" {
            // The command ran and refused; its own words name the reason.
            throw CallError(code: "command-error", message: said ?? "The Mac refused that command.")
        }
        return said ?? ""
    }

    /// Branch a conversation, keeping its history up to now.
    ///
    /// - Returns: the new session's id.
    public func fork(sessionId: String) async throws -> String {
        let value = try await transport.call("session/fork", .object(["request": .object(["sessionId": .string(sessionId)])]))
        guard let id = value["sessionId"]?.stringValue else {
            throw CallError(code: "internal", message: "The Mac branched the conversation but didn’t say where to.")
        }
        return id
    }

    /// Take a conversation out of the list without destroying it. A workspace
    /// operation: the session is intact and the Mac can bring it back.
    public func archive(sessionId: String) async throws {
        try await transport.call("workspace/archiveSession", .object(["request": .object(["sessionId": .string(sessionId)])]))
    }

    /// Put an archived conversation back in the list.
    public func unarchive(sessionId: String) async throws {
        try await transport.call("workspace/unarchiveSession", .object(["request": .object(["sessionId": .string(sessionId)])]))
    }

    /// The machine's access presets: the ones a conversation can be switched
    /// to, and what new conversations start as.
    ///
    /// The first half is here because dsh 0.2's `permissions` projection names
    /// only the preset a conversation is on, not the others it could be on.
    /// The second is not a session's projection at all — it is about
    /// conversations that do not exist yet.
    public func permissionPresets() async throws -> (options: [PermissionChoice.Option], defaults: PermissionChoice?) {
        let value = try await transport.call("permissionPresets/catalog", .emptyObject)
        let defaults = value["defaultPreset"]?.stringValue.map {
            PermissionChoice(current: $0, options: PermissionChoice.options(value["defaultOptions"] ?? value["options"]))
        }
        return (PermissionChoice.options(value["options"]), defaults)
    }

    /// Change what new conversations start as.
    ///
    /// Two calls, because the settings are written with optimistic
    /// concurrency: read the namespace's revision, then patch against it. A
    /// stale revision is refused rather than overwriting whoever changed it in
    /// between — most likely the person at the Mac. A conversation that is
    /// already running is changed with `/permission` (`command`) instead.
    public func setPermission(_ preset: String) async throws {
        let described = try await transport.call("settings/describe", .emptyObject)
        let revision = (described["namespaces"]?.arrayValue ?? [])
            .first { $0["ns"]?.stringValue == "permission" }?["revision"]?.intValue
        try await transport.call("settings/update", .object(dropping: [
            "ns": .string("permission"),
            "patch": .object(["defaultPreset": .string(preset)]),
            "expectedRevision": revision.map { JSONValue.number(Double($0)) },
        ]))
    }

    /// Set a session's title by hand.
    public func rename(sessionId: String, title: String) async throws {
        try await transport.call("session/rename", .object(["request": .object([
            "sessionId": .string(sessionId),
            "title": .string(title),
        ])]))
    }

    /// Search the message surface across conversations.
    ///
    /// Off unless the machine's dsh has its session index switched on; then the
    /// call fails with a message that says so, which the caller shows.
    public func search(query: String) async throws -> (hits: [SearchHit], hasMore: Bool) {
        let value = try await transport.call("session/search", .object(["request": .object(["query": .string(query)])]))
        let hits = (value["items"]?.arrayValue ?? []).compactMap { item -> SearchHit? in
            guard let id = item["sessionId"]?.stringValue else { return nil }
            return SearchHit(id: id, snippet: item["snippet"]?.stringValue ?? "")
        }
        return (hits, value["hasMore"]?.boolValue ?? false)
    }

    /// Edit, remove, or steer one queued message.
    public func updateQueue(sessionId: String, itemId: String, action: QueueAction) async throws {
        var payload: JSONValue = .object(["kind": .string(action.kind)])
        if case .edit(let text) = action {
            payload = .object([
                "kind": .string("edit"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ])
        }
        try await transport.call("session/updateQueue", .object(["request": .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
            "action": payload,
        ])]))
    }

    /// Fetch one image referenced by a message, as base64.
    public func attachment(sessionId: String, attachmentId: String) async throws -> (mediaType: String, base64: String) {
        let value = try await transport.call("session/attachment", .object(["request": .object([
            "sessionId": .string(sessionId),
            "attachmentId": .string(attachmentId),
        ])]))
        return (
            value.path("attachment", "mediaType")?.stringValue ?? "image/png",
            value["data"]?.stringValue ?? ""
        )
    }

    /// The current projections of one session: title, stats, permissions,
    /// model selection, subagents and the rest (docs/dsh-0.2-protocol.md §6).
    public func projections(sessionId: String) async throws -> JSONValue {
        let value = try await transport.call("session/projections", .object(["request": .object(["sessionId": .string(sessionId)])]))
        return value["values"] ?? .emptyObject
    }

    /// The children this session spawned.
    ///
    /// dsh 0.2 has no listing endpoint for this. The parent's `subagentCatalog`
    /// projection names its children and how they run; the session list says
    /// which are live and which spawned children of their own.
    public func subagents(parentSessionId: String) async throws -> (children: [SubagentChild], available: Bool) {
        async let values = projections(sessionId: parentSessionId)
        async let rows = listSessions()
        let catalog = (try await values)["subagentCatalog"]?.arrayValue ?? []
        let sessions = try await rows
        let children = catalog.compactMap { entry -> SubagentChild? in
            guard let id = entry["id"]?.stringValue else { return nil }
            let row = sessions.first { $0.id == id }
            return SubagentChild(
                catalog: entry,
                running: row?.running ?? false,
                hasChildren: sessions.contains { $0.parentSessionId == id }
            )
        }
        return (children, true)
    }

    /// The skills available in a session. Per session: skills can be scoped.
    public func skills(sessionId: String) async throws -> [SlashCommand] {
        let value = try await transport.call("skills/list", .object(["request": .object(["sessionId": .string(sessionId)])]))
        return (value["skills"]?.arrayValue ?? []).compactMap { SlashCommand($0) }
    }

    /// The commands the machine will run for a session: `/permission`,
    /// `/compact`, `/goal`, and whatever a mounted plugin registers. Different
    /// from skills: a skill is text the model reads, a command is something the
    /// machine executes.
    public func commands(sessionId: String) async throws -> [SlashCommand] {
        let value = try await transport.call("commands/list", .object(["agentId": .string(sessionId)]))
        return (value.arrayValue ?? []).compactMap(SlashCommand.init(command:))
    }

    // MARK: - Models

    /// The models this session can switch to, with the one it is on.
    ///
    /// The catalog is the machine's; which model the session is on is its
    /// `modelSelection` projection — the next turn's choice, else the last.
    public func models(sessionId: String) async throws -> ModelCatalog {
        async let catalog = transport.call("session/modelCatalog", .emptyObject)
        async let values = projections(sessionId: sessionId)
        let selection = (try? await values)?["modelSelection"]
        let chosen = selection?["next"] ?? selection?["lastUsed"]
        return Harness.catalog(try await catalog, current: chosen)
    }

    /// Every model the machine can route to, independent of any session.
    public func machineModels() async throws -> ModelCatalog {
        Harness.catalog(try await transport.call("session/modelCatalog", .emptyObject), current: nil)
    }

    /// Read a `session/modelCatalog` answer. `current` overrides the machine's
    /// default with a session's own selection.
    static func catalog(_ value: JSONValue, current chosen: JSONValue?) -> ModelCatalog {
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
        let selected = chosen ?? value["default"]
        let currentProvider = selected?["provider"]?.stringValue
        let currentModel = selected?["model"]?.stringValue
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
            currentEffort: selected?["reasoningEffort"]?.stringValue
        )
    }

    /// Switch this session's model.
    public func selectModel(sessionId: String, option: ModelOption, reasoningEffort: String? = nil) async throws {
        try await transport.call("session/selectModel", .object(["request": .object(dropping: [
            "sessionId": .string(sessionId),
            "provider": .string(option.provider),
            "model": .string(option.model),
            "reasoningEffort": reasoningEffort.map(JSONValue.string),
        ])]))
    }

    // MARK: - Answering the agent
    //
    // Both answers go to `$events/result`, as this app's own `$events` client:
    // `clientId` is the one the stream that delivered the request was given,
    // `eventId` is the request's. The first answer from any client wins; one
    // that arrives after is accepted and changes nothing (docs/dsh-0.2-protocol.md §5.4).

    /// Allow or refuse one tool call.
    public func answerApproval(_ request: ApprovalRequest, allow: Bool) async throws {
        try await answer(clientId: request.clientId, eventId: request.id, value: .string(allow ? "allowed-once" : "rejected"))
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
        try await answer(clientId: request.clientId, eventId: request.id, value: .object(["answers": .array(payload)]))
    }

    private func answer(clientId: String, eventId: String, value: JSONValue) async throws {
        try await transport.call("$events/result", .object([
            "clientId": .string(clientId),
            "eventId": .string(eventId),
            "outcome": .object(["kind": .string("result"), "value": value]),
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
