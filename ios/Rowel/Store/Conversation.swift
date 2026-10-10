/// One session's transcript, folded from its event log.
///
/// The harness never sends a rendered view. It sends the same append-only event
/// log it persists, and every client folds it into whatever it wants to show.
/// That is what lets this app render a conversation started in the web UI: the
/// fold is a pure function of the events.
///
/// dsh 0.2 delivers it through `session/follow` (docs/dsh-0.2-protocol.md §4):
/// a snapshot of the tail, then every event after it, in order. A follow cannot
/// resume from a position, so every reconnect brings a new snapshot, and the
/// snapshot replaces what was held — `adopt(snapshot:)`.
///
/// Three rules the fold depends on:
///
/// - **Events are numbered and ordered.** `seq` dedupes, so an older page that
///   overlaps what is held cannot double-render a message.
/// - **The model's output streams outside the log.** `assistant-stream` frames
///   build a bubble token by token and are never persisted; the
///   `assistant/message` that follows replaces the bubble with the assembled
///   content. An attempt dsh abandons leaves nothing in the log, so its bubble
///   is taken down — `receiveStream(_:)`.
/// - **Tool cards are drawn here.** dsh 0.2 attaches no rendering hints to a
///   tool call; the card is chosen from the tool's name and arguments.

import Foundation

@MainActor
@Observable
public final class Conversation {
    public let sessionId: String

    /// The transcript, in log order.
    public private(set) var items: [ConversationItem] = []
    /// True between `turn/start` and `turn/end`.
    public private(set) var running = false
    public private(set) var title: String?
    public private(set) var todos: [TodoItem] = []
    /// Messages sent but not yet claimed by the agent.
    public private(set) var queue: [QueuedMessage] = []
    /// Fraction of the context window in use, when the machine reports it.
    public private(set) var contextFraction: Double?
    /// Tokens in the window and its size, kept alongside the fraction because
    /// "83%" and "830k of 1M" answer different questions.
    public private(set) var contextTokens: Int?
    public private(set) var contextWindow: Int?
    /// Turns, steps, and timings. Nil until the first turn has run.
    public private(set) var stats: SessionStats?
    /// Tokens in and out, and how much of the input was cached.
    public private(set) var tokens: TokenUsage?
    /// Where the context has gone: system prompt, tool schemas, conversation.
    public private(set) var contextBreakdown: ContextBreakdown?
    /// How much the agent may touch, and what else it could be set to.
    public private(set) var permissions: PermissionChoice?
    /// The presets a conversation can be switched to, from the machine's
    /// catalog: dsh 0.2's `permissions` projection names only the current one.
    private var presetOptions: [PermissionChoice.Option] = []
    /// Skills this session offers, from `skills/list`. Fetched once; skills do
    /// not appear mid-sentence, and a request per keystroke would.
    public var skills: [SlashCommand] = []
    /// Whether `skills` is the machine's answer rather than the empty default.
    public var skillsKnown = false
    /// Commands the *machine* will run for this session, from `commands/list`.
    ///
    /// Kept apart from the skills because sending them is a different act: a
    /// skill is text the model reads, a command is handed to `commands/execute`.
    /// `machineLine(for:)` is the whole of that decision.
    public var machineCommands: [SlashCommand] = []
    /// Whether `machineCommands` is the machine's answer. Until it is, a slash
    /// line cannot be routed as a command — so it is fetched again on reconnect.
    public var commandsKnown = false

    /// Everything the composer offers after a slash, commands first.
    ///
    /// Commands first because they are the ones with a right answer — a skill
    /// name is a word the model may or may not know, while `/permission` with no
    /// argument prints what it is currently set to.
    public var slashCommands: [SlashCommand] { machineCommands + skills }

    /// The command line to run on the machine, when `text` names one.
    ///
    /// Only a name the machine listed counts, and `machineCommand(in:among:)` is
    /// where that is decided — the composer asks the same question before it
    /// sends. Everything else that starts with a slash — a path, a sentence, a
    /// skill — has to keep going to the model as a message, which is what the app
    /// did before commands were routable and what a stray `/tmp is full` still
    /// needs. An older dsh that lists no commands therefore routes nothing, and
    /// loses nothing.
    public func machineLine(for text: String) -> String? {
        guard machineCommand(in: text, among: machineCommands) != nil else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Children this session spawned, and whether the machine could say.
    public var subagents: [SubagentChild] = []
    public var subagentsKnown = false
    /// Set when a `subagent/descriptor` event lands, so the list is refetched
    /// rather than going stale the moment the agent spawns something.
    public private(set) var subagentsStale = false
    /// Whether the session is in plan mode, which changes what the composer says.
    public private(set) var planning = false
    /// The session's working directory, learned from the summary.
    public var cwd: String?
    /// The model in use, for the header.
    public private(set) var modelName: String?

    /// True while the first snapshot, or an older page, is on its way.
    public var loading = false
    /// True when older pages exist.
    public private(set) var hasMore = false
    /// Lowest event sequence held, the cursor for loading older pages.
    public private(set) var oldestSeq: Int?
    /// Highest event sequence held: the snapshot's cursor, then every event
    /// folded after it. An older page is read through this, so it comes from
    /// the same log the window does.
    public private(set) var cursor: Int?
    /// True once a snapshot has landed, so the view can tell empty from unloaded.
    public private(set) var loaded = false
    /// Bumped whenever the window is replaced. An older page asked for before
    /// that must not land after it: it was read against a window that is gone.
    public private(set) var generation = 0

    /// The attempt the model is streaming now, from its `start` frame: which
    /// bubble its chunks belong to.
    private var streaming: (attemptId: String, turn: Int, step: Int)?

    /// Streaming bubbles by `turn.step`.
    private var assistantIndex: [String: Int] = [:]
    /// Tool cards by call id.
    private var toolIndex: [String: Int] = [:]
    /// Event sequences already folded.
    private var seen: Set<Int> = []
    /// Command lines that have started and not yet finished, by the machine's
    /// command id — the join between `command/run` and `command/done`.
    private var runningCommands: [String: String] = [:]
    /// Projection watermarks, so an out-of-order projection frame cannot go backwards.
    private var projectionSeq: [String: Int] = [:]
    /// Optimistic bubbles, by the `requestId` they were sent under, holding the
    /// text they were shown with.
    ///
    /// The harness mints its own id for a message, but logs the sender's
    /// `requestId` on it as `source.rpcId` — that is the join. Without it the
    /// optimistic copy stays on screen and every message appears twice.
    private var pending: [(id: String, text: String)] = []
    /// Queue entries shown before the machine listed them, by `requestId`.
    /// Kept across `inbox` updates until the machine's own entry, or the
    /// message itself, says where it went.
    private var provisional: [QueuedMessage] = []

    public init(sessionId: String, title: String? = nil, cwd: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
    }

    // MARK: - History

    /// Replace everything with a snapshot from `session/follow`.
    ///
    /// Swapped in whole rather than merged, as dsh's own client does: the
    /// snapshot is the tail of the log as of its `cursor`, and every event after
    /// it follows on the same stream. Older pages loaded before are dropped, and
    /// scrolling back fetches them again. What this device sent and the machine
    /// has not logged yet survives the swap — that message is still on its way.
    public func adopt(snapshot: JSONValue) {
        generation += 1
        items = []
        assistantIndex = [:]
        toolIndex = [:]
        seen = []
        runningCommands = [:]
        // Projection watermarks are kept: `session/control` is a separate
        // stream, and a value it delivered after this snapshot was taken must
        // not be put back by the snapshot's older one.
        streaming = nil
        oldestSeq = nil
        cursor = nil
        let records = snapshot["records"]?.arrayValue ?? []
        for record in records {
            guard let event = record["event"] else { continue }
            apply(event: event)
        }
        oldestSeq = records.first?["event"]?["seq"]?.intValue
        cursor = snapshot["cursor"]?.intValue ?? cursor
        hasMore = snapshot["hasMore"]?.boolValue ?? false
        if let projections = snapshot["projections"] {
            absorbProjections(projections)
        }
        if let attempt = snapshot.path("assistantStream", "activeAttempt") {
            resume(attempt)
        }
        // Whatever the log did not confirm goes back where it was: at the end.
        for entry in pending {
            append(.user(UserTurn(id: entry.id, text: entry.text, images: [], synthetic: false, at: Date())))
        }
        loaded = true
    }

    /// Fold an older page from `session/page` in front of what is held.
    public func absorb(page: JSONValue) {
        let records = page["records"]?.arrayValue ?? []
        // Folded into a scratch conversation and spliced, which keeps the fold
        // itself append-only — the only order it is correct in.
        let older = Conversation(sessionId: sessionId)
        for record in records {
            guard let event = record["event"] else { continue }
            older.apply(event: event)
        }
        let held = Set(items.map(\.id))
        items.insert(contentsOf: older.items.filter { !held.contains($0.id) }, at: 0)
        reindex()
        seen.formUnion(older.seen)
        if let first = records.first?["event"]?["seq"]?.intValue {
            oldestSeq = min(oldestSeq ?? first, first)
        }
        hasMore = page["hasMore"]?.boolValue ?? false
    }

    /// Show a title this device just set, until the machine's own projection
    /// says otherwise. Not through `applyProjection`: a watermark raised for a
    /// local guess would outrank every later rename made on the Mac.
    public func retitle(_ title: String) {
        self.title = title
    }

    /// Apply a projection block: a snapshot's, or one session's share of the
    /// `session/control` baseline.
    public func absorbProjections(_ block: JSONValue) {
        let asOf = block["asOfSeq"]?.intValue ?? 0
        for (key, value) in block["values"]?.objectValue ?? [:] {
            applyProjection(key: key, value: value, seq: asOf)
        }
    }

    // MARK: - Streaming

    /// Fold one `assistant-stream` frame (docs/dsh-0.2-protocol.md §4.2).
    ///
    /// `start` names the bubble, `chunk` grows it, `end` settles it. The
    /// persisted `assistant/message` arrives before `end` and has already
    /// replaced the bubble's text by then; an `abandoned` attempt has no such
    /// message, and what it streamed is taken down.
    public func receiveStream(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "start":
            guard let id = frame["attemptId"]?.stringValue else { return }
            streaming = (id, frame["turn"]?.intValue ?? 0, frame["step"]?.intValue ?? 0)
        case "chunk":
            guard let attempt = streaming, frame["attemptId"]?.stringValue == attempt.attemptId,
                  let chunk = frame["chunk"] else { return }
            applyChunk(chunk, turn: attempt.turn, step: attempt.step, at: Conversation.date(frame["time"]))
        case "end":
            guard let attempt = streaming, frame["attemptId"]?.stringValue == attempt.attemptId else { return }
            streaming = nil
            if frame.path("outcome", "kind")?.stringValue == "abandoned" {
                dropStreamed(turn: attempt.turn, step: attempt.step)
            }
        default:
            break
        }
    }

    /// Pick up an attempt that was already streaming when the snapshot was
    /// taken: its output so far, in the log's compact form, then the frames
    /// that follow on the stream.
    private func resume(_ attempt: JSONValue) {
        guard let id = attempt["attemptId"]?.stringValue else { return }
        let turn = attempt["turn"]?.intValue ?? 0
        let step = attempt["step"]?.intValue ?? 0
        streaming = (id, turn, step)
        for record in attempt["stream"]?.arrayValue ?? [] {
            let text = (record["texts"]?.arrayValue ?? []).compactMap(\.stringValue).joined()
            let at = Conversation.date(record["time0"] ?? record["time"])
            switch record["type"]?.stringValue {
            case "text-chunks" where !text.isEmpty:
                mutateAssistant(turn: turn, step: step, at: at) { $0.text += text }
            case "reasoning-chunks" where !text.isEmpty:
                mutateAssistant(turn: turn, step: step, at: at) { $0.reasoning += text }
            case "chunk":
                if let chunk = record["chunk"] { applyChunk(chunk, turn: turn, step: step, at: at) }
            default:
                break
            }
        }
    }

    /// Take down a bubble whose text the log will never hold.
    private func dropStreamed(turn: Int, step: Int) {
        guard let index = assistantIndex["\(turn).\(step)"], case .assistant(let bubble) = items[index],
              !bubble.complete else { return }
        items.remove(at: index)
        reindex()
    }

    static func date(_ milliseconds: JSONValue?) -> Date {
        guard let value = milliseconds?.doubleValue else { return Date() }
        return Date(timeIntervalSince1970: value / 1000)
    }

    /// Apply one projection change: from `session/control`, or a block above.
    public func applyProjection(key: String, value: JSONValue, seq: Int) {
        // Higher sequence wins. Frames can overtake the history baseline on a
        // reconnect, and a stale one must not undo a newer value.
        if let held = projectionSeq[key], held > seq { return }
        projectionSeq[key] = seq
        switch key {
        case "title":
            title = value.stringValue
        case "todos":
            todos = (value.arrayValue ?? []).compactMap { item in
                guard let content = item["content"]?.stringValue,
                      let status = TodoItem.Status(rawValue: item["status"]?.stringValue ?? "") else { return nil }
                return TodoItem(content: content, status: status)
            }
        case "contextPressure":
            let window = value["contextWindow"]?.doubleValue
            let used = value["projectedTokens"]?.doubleValue ?? value["pressureTokens"]?.doubleValue
            if let window, window > 0, let used {
                contextFraction = min(1, used / window)
            } else {
                contextFraction = nil
            }
            contextTokens = value["projectedTokens"]?.intValue ?? value["pressureTokens"]?.intValue
            contextWindow = value["contextWindow"]?.intValue
        case "plan":
            planning = value["mode"]?.stringValue == "plan" || value["active"]?.boolValue == true
        // The four below were already arriving and being discarded. Folding them
        // is a `case` each; the alternative was a request per number.
        case "sessionStats":
            stats = SessionStats(value)
        case "tokenUsage":
            tokens = TokenUsage(value)
        case "contextBreakdown":
            contextBreakdown = ContextBreakdown(value)
        case "permissions":
            permissions = PermissionChoice(value).map { choice in
                choice.options.isEmpty ? PermissionChoice(current: choice.current, options: presetOptions) : choice
            }
        case "inbox":
            applyInbox(value)
        default:
            break
        }
    }

    /// Take the refetch flag, so a caller cannot loop on it.
    public func consumeSubagentsStale() -> Bool {
        defer { subagentsStale = false }
        return subagentsStale
    }

    // MARK: - Events

    /// Fold one session event.
    public func apply(event: JSONValue) {
        guard let type = event["type"]?.stringValue else { return }
        let seq = event["seq"]?.intValue ?? 0
        guard seen.insert(seq).inserted else { return }
        cursor = max(cursor ?? seq, seq)
        let at = Conversation.date(event["time"])
        let data = event["data"] ?? .emptyObject

        switch type {
        case "turn/start":
            running = true
        case "turn/end":
            running = false
            completeStreaming()
            if let reason = data["reason"]?["kind"]?.stringValue, reason != "success", reason != "completed" {
                let detail = data.path("reason", "error", "message")?.stringValue
                    ?? data.path("reason", "message")?.stringValue
                    ?? data.path("reason", "failure", "message")?.stringValue
                if let detail, !detail.isEmpty {
                    append(.notice(Notice(id: "n\(seq)", kind: .failure, text: detail, at: at)))
                }
            }
        case "command/run":
            // Remembered rather than drawn: `command/done` follows within the
            // round trip and is the half with something to say. The pairing is
            // what makes that half readable — the done event carries an id and
            // an outcome, not the words that produced them.
            if let id = data["commandId"]?.stringValue {
                let name = data["name"]?.stringValue ?? ""
                let args = data["args"]?.stringValue ?? ""
                runningCommands[id] = "/\(name)\(args)"
            }
        case "command/done":
            let id = data["commandId"]?.stringValue ?? ""
            let line = runningCommands.removeValue(forKey: id)
            let said = data["text"]?.stringValue ?? ""
            // A command that was run from the browser, or from a log page
            // loaded after the fact, has no `command/run` here to pair with. The
            // outcome is still worth a line — it is the session's own record of
            // what happened — so it goes out on its own.
            let text = [line, said].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            if !text.isEmpty {
                append(.notice(Notice(
                    id: "cmd-\(seq)",
                    kind: data["kind"]?.stringValue == "error" ? .failure : .info,
                    text: text,
                    at: at
                )))
            }
        case "user/message":
            appendUserMessage(data, seq: seq, at: at)
        case "assistant/message":
            finishAssistant(data, seq: seq, at: at)
        case "assistant/attempt":
            // An attempt that ended without a message — a failure, or one a
            // retry replaces. What it streamed is not the answer; the retry
            // streams into the same step.
            dropStreamed(turn: data["turn"]?.intValue ?? 0, step: data["step"]?.intValue ?? 0)
        case "session/title":
            if let named = data["title"]?.stringValue { title = named }
        case "tool/call":
            openToolCard(data, at: at)
        case "tool/result":
            // A result with no card to land on is not folded, so its sequence
            // is not spent either: were its call to arrive later, the result
            // re-delivered behind it has to be able to land.
            if !closeToolCard(data, at: at) { seen.remove(seq) }
        case "todo/write":
            todos = (data["todos"]?.arrayValue ?? []).compactMap { item in
                guard let content = item["content"]?.stringValue,
                      let status = TodoItem.Status(rawValue: item["status"]?.stringValue ?? "") else { return nil }
                return TodoItem(content: content, status: status)
            }
        case "subagent/descriptor":
            // The descriptor itself is the machine's business — it carries
            // model-hidden content and the fold has no use for it. What matters
            // here is only that the child list just changed.
            subagentsStale = true
        case "request/header":
            modelName = data.path("header", "config", "model")?.stringValue ?? modelName
        default:
            // Log-only events (`step/start`, `request/context`, `agent/inbox/spliced`
            // — the `inbox` projection says the same, whole)
            // and every event a plugin adds after this build shipped. Silence is
            // the documented default; a client that guessed would render noise.
            break
        }
    }

    private func appendUserMessage(_ message: JSONValue, seq: Int, at: Date) {
        let kind = message.path("source", "kind")?.stringValue ?? "user"
        // A tool result reaches the log as `tool/result`; if one shows up here it
        // is a duplicate of a card already on screen.
        if kind == "tool" { return }
        let blocks = message["content"]?.arrayValue ?? []
        let text = Conversation.plainText(blocks)
        let images: [ImageAttachment] = blocks.compactMap { block in
            guard block["type"]?.stringValue == "image", let ref = block["attachment"] else { return nil }
            guard let id = ref["attachmentId"]?.stringValue else { return nil }
            return ImageAttachment(id: id, mediaType: ref["mediaType"]?.stringValue ?? "image/png", base64: nil)
        }
        if kind == "runtime-context" {
            // The machine's own note to the model about where it is running,
            // refreshed every turn. Nobody said it, and shown it would be a
            // page of boilerplate in front of every answer.
            return
        }
        if kind != "user" {
            // Injected context: a file-change notice, an AGENTS.md, a skill body.
            // It is real model input, so hiding it would misrepresent the
            // conversation, but it did not come from the person either.
            let summary = message.path("source", "summary")?.stringValue
            let id = message["id"]?.stringValue ?? "u\(seq)"
            append(.user(UserTurn(id: id, text: summary ?? text, images: images, synthetic: true, at: at)))
            return
        }
        if text.isEmpty && images.isEmpty { return }
        // The real copy of something this device sent: the `requestId` it went
        // under comes back as `source.rpcId`. Its optimistic bubble and its
        // provisional queue entry are retired here rather than by the `inbox`
        // update, which can be missed across a reconnect.
        if let requestId = message.path("source", "rpcId")?.stringValue {
            clearPending(requestId)
            provisional.removeAll { $0.id == requestId }
            queue.removeAll { $0.id == requestId }
        }
        let id = message["id"]?.stringValue ?? "u\(seq)"
        append(.user(UserTurn(id: id, text: text, images: images, synthetic: false, at: at)))
    }

    /// Remove the optimistic bubble sent under this `requestId`.
    private func clearPending(_ requestId: String) {
        guard let index = pending.firstIndex(where: { $0.id == requestId }) else { return }
        pending.remove(at: index)
        items.removeAll { $0.id == requestId }
        reindex()
    }

    private func applyChunk(_ chunk: JSONValue, turn: Int, step: Int, at: Date) {
        guard let kind = chunk["type"]?.stringValue else { return }
        switch kind {
        case "text-delta":
            guard let text = chunk["text"]?.stringValue, !text.isEmpty else { return }
            mutateAssistant(turn: turn, step: step, at: at) { $0.text += text }
        case "reasoning-delta":
            guard let text = chunk["text"]?.stringValue, !text.isEmpty else { return }
            mutateAssistant(turn: turn, step: step, at: at) { $0.reasoning += text }
        default:
            // `tool-call-delta` is covered by the `tool/call` event that follows,
            // and `usage`/`finish`/`block-*` carry nothing to render.
            break
        }
    }

    private func finishAssistant(_ data: JSONValue, seq: Int, at: Date) {
        let turn = data["turn"]?.intValue ?? 0
        let step = data["step"]?.intValue ?? 0
        let blocks = data.path("message", "content")?.arrayValue ?? []
        let text = Conversation.plainText(blocks)
        let reasoning = Conversation.joined(blocks, ofType: "reasoning")
        let key = "\(turn).\(step)"
        if text.isEmpty && reasoning.isEmpty {
            // A step that only called tools. The tool cards carry it; an empty
            // bubble above them would just be a gap.
            if let index = assistantIndex.removeValue(forKey: key) {
                items.remove(at: index)
                reindex()
            }
            return
        }
        mutateAssistant(turn: turn, step: step, at: at) {
            $0.text = text
            $0.reasoning = reasoning
            $0.complete = true
        }
    }

    private func mutateAssistant(turn: Int, step: Int, at: Date, _ change: (inout AssistantTurn) -> Void) {
        let key = "\(turn).\(step)"
        if let index = assistantIndex[key], case .assistant(var turnItem) = items[index] {
            change(&turnItem)
            items[index] = .assistant(turnItem)
            return
        }
        var fresh = AssistantTurn(id: "a\(key)", turn: turn, step: step, text: "", reasoning: "", complete: false, at: at)
        change(&fresh)
        assistantIndex[key] = items.count
        items.append(.assistant(fresh))
    }

    private func openToolCard(_ data: JSONValue, at: Date) {
        guard let callId = data["callId"]?.stringValue else { return }
        let name = data["name"]?.stringValue ?? "tool"
        let arguments = data["arguments"]?.stringValue ?? "{}"
        let presentation = Conversation.questionPresentation(name: name, arguments: arguments)
            ?? Conversation.callPresentation(name: name, arguments: arguments)
        let card = ToolCard(
            id: callId,
            name: name,
            arguments: arguments,
            presentation: presentation,
            resultText: nil,
            failed: false,
            running: true,
            at: at
        )
        if let index = toolIndex[callId] {
            items[index] = .tool(card)
            return
        }
        toolIndex[callId] = items.count
        items.append(.tool(card))
    }

    @discardableResult
    private func closeToolCard(_ data: JSONValue, at: Date) -> Bool {
        let message = data["message"] ?? .emptyObject
        let callId = message.path("source", "callId")?.stringValue ?? message["toolCallId"]?.stringValue
        guard let callId, let index = toolIndex[callId], case .tool(var card) = items[index] else { return false }
        card.running = false
        card.finishedAt = at
        card.failed = data["error"] != nil && data["error"]?.isNull == false
            || message["isError"]?.boolValue == true
        card.resultText = Conversation.plainText(message["content"]?.arrayValue ?? [])
        if case .question(let questions, _) = card.presentation {
            card.presentation = .question(items: questions, answers: card.failed ? nil : Conversation.answers(in: card.resultText))
        } else {
            card.presentation = Conversation.resultPresentation(card.resultText, current: card.presentation)
        }
        items[index] = .tool(card)
        return true
    }

    /// Mark any still-streaming bubble finished. A turn can end without a final
    /// message — cancellation, a provider error — and a bubble left with its
    /// caret blinking would claim the answer is still coming.
    private func completeStreaming() {
        for index in assistantIndex.values {
            guard index < items.count, case .assistant(var turnItem) = items[index], !turnItem.complete else { continue }
            turnItem.complete = true
            items[index] = .assistant(turnItem)
        }
        for index in toolIndex.values {
            guard index < items.count, case .tool(var card) = items[index], card.running else { continue }
            card.running = false
            items[index] = .tool(card)
        }
    }

    private func append(_ item: ConversationItem) {
        items.append(item)
    }

    /// Rebuild the index maps after an insert or a removal shifted positions.
    private func reindex() {
        assistantIndex = [:]
        toolIndex = [:]
        for (index, item) in items.enumerated() {
            switch item {
            case .assistant(let turnItem): assistantIndex["\(turnItem.turn).\(turnItem.step)"] = index
            case .tool(let card): toolIndex[card.id] = index
            default: break
            }
        }
    }

    // MARK: - Side channels

    /// Apply the `inbox` projection: messages sent and not yet claimed, those
    /// waiting for the next turn and those to be cut into the running one. The
    /// whole set arrives every time, so this replaces rather than merges —
    /// except for what this device sent and the machine has not listed yet.
    func applyInbox(_ value: JSONValue) {
        var listed: [QueuedMessage] = []
        var requestIds: Set<String> = []
        for (target, placement) in [("next-step", "steering"), ("next-turn", "queued")] {
            for message in value[target]?.arrayValue ?? [] {
                guard let id = message["id"]?.stringValue else { continue }
                if let requestId = message.path("source", "rpcId")?.stringValue { requestIds.insert(requestId) }
                let text = Conversation.plainText(message["content"]?.arrayValue ?? [])
                listed.append(QueuedMessage(id: id, text: text, placement: placement))
            }
        }
        provisional.removeAll { requestIds.contains($0.id) }
        queue = listed + provisional
    }

    /// Learn the presets this machine offers, for a projection that names
    /// only the current one.
    public func offer(presets: [PermissionChoice.Option]) {
        presetOptions = presets
        if let held = permissions, held.options.isEmpty {
            permissions = PermissionChoice(current: held.current, options: presets)
        }
    }

    /// State the model without waiting for a turn.
    ///
    /// The fold learns the model from `request/header`, which only exists once
    /// something has run. A session that has never run still has a model, and
    /// showing it is what lets someone notice it is the wrong one before they
    /// spend a turn finding out.
    public func setModel(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        modelName = name
    }

    public func setRunning(_ value: Bool) {
        running = value
        if !value { completeStreaming() }
    }

    /// Show a message in the queue strip before the machine has listed it,
    /// under the `requestId` it is sent with. The machine's own entry replaces
    /// it the moment `inbox` names that request — same shape as `showPending`,
    /// aimed at the other place.
    public func showQueued(text: String, id: String) {
        let entry = QueuedMessage(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), placement: "queued")
        provisional.append(entry)
        queue.append(entry)
    }

    /// Take back a provisional queue entry whose send failed. A no-op when the
    /// machine has already listed it, which is the correct outcome: the
    /// machine's word beats the guess.
    public func dropQueued(id: String) {
        provisional.removeAll { $0.id == id }
        queue.removeAll { $0.id == id }
    }

    /// Whether the machine has listed this queue entry. Until it has, the
    /// entry has no id the machine knows, so it cannot be steered or taken
    /// back yet.
    public func isListed(_ item: QueuedMessage) -> Bool {
        !provisional.contains { $0.id == item.id }
    }

    /// Show an entry as steering into the running turn, or as queued again,
    /// before the machine's `inbox` says so — which it does, and wins.
    public func setPlacement(_ placement: String, of id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].placement = placement
    }

    /// Show a message optimistically, before the machine has logged it, under
    /// the `requestId` it is sent with. The real `user/message` names that
    /// request and replaces it.
    public func showPending(text: String, id: String) {
        pending.append((id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        append(.user(UserTurn(id: id, text: text, images: [], synthetic: false, at: Date())))
    }

    /// Whether an optimistic message is still waiting for the machine's copy.
    public func isPending(id: String) -> Bool {
        pending.contains { $0.id == id }
    }

    /// Whether a provisional queue entry is still the one on screen.
    public func isQueued(id: String) -> Bool {
        queue.contains { $0.id == id }
    }

    /// Drop an optimistic message whose send failed.
    public func dropPending(id: String) {
        pending.removeAll { $0.id == id }
        items.removeAll { $0.id == id }
        reindex()
    }

    public func note(_ text: String, kind: Notice.Kind = .warning) {
        append(.notice(Notice(id: "note-\(items.count)-\(text.hashValue)", kind: kind, text: text, at: Date())))
    }
}

// MARK: - View parsing

extension Conversation {
    /// Concatenate the text blocks of a content array.
    static func plainText(_ blocks: [JSONValue]) -> String {
        joined(blocks, ofType: "text")
    }

    static func joined(_ blocks: [JSONValue], ofType type: String) -> String {
        blocks
            .filter { $0["type"]?.stringValue == type }
            .compactMap { $0["text"]?.stringValue }
            .joined()
    }

    /// `ask_user_question` as a question card, from the questions in its
    /// arguments. Nil — and so the generic card — unless every one of them can
    /// be read: a card that shows the raw call beats one that shows nothing,
    /// and beats one that silently leaves a question out.
    static func questionPresentation(name: String, arguments: String) -> ToolPresentation? {
        guard name == "ask_user_question",
              let questions = (try? JSONValue(data: Data(arguments.utf8)))?["questions"]?.arrayValue,
              !questions.isEmpty
        else { return nil }
        let items = questions.compactMap(QuestionItem.init(json:))
        return items.count == questions.count ? .question(items: items, answers: nil) : nil
    }

    /// The person's answers, from the result text dsh logs for the tool:
    /// `{"answers":[{"id":…,"selected":[…],"custom":…}]}` — the same shape
    /// `Harness.answerQuestion` sends. Nil when it is not that.
    static func answers(in text: String?) -> [String: QuestionAnswer]? {
        guard let text, let list = (try? JSONValue(data: Data(text.utf8)))?["answers"]?.arrayValue else { return nil }
        var answers: [String: QuestionAnswer] = [:]
        for entry in list {
            guard let id = entry["id"]?.stringValue else { continue }
            answers[id] = QuestionAnswer(
                selected: (entry["selected"]?.arrayValue ?? []).compactMap(\.stringValue),
                custom: entry["custom"]?.stringValue
            )
        }
        return answers
    }

    /// Choose a card for a tool call from its name and arguments.
    ///
    /// dsh 0.2 sends no render hints (docs/dsh-0.2-protocol.md §8.2), so the
    /// tools worth a dedicated card are named here — the shell, the two file
    /// writers, the two searches. Everything else, including whatever a plugin
    /// adds, gets the generic card with its most telling argument.
    static func callPresentation(name: String, arguments: String) -> ToolPresentation {
        let input = (try? JSONValue(data: Data(arguments.utf8))) ?? .emptyObject
        let path = input["file_path"]?.stringValue
        switch name {
        case "bash":
            return .terminal(
                command: input["command"]?.stringValue ?? name,
                cwd: input["workdir"]?.stringValue,
                output: nil,
                exitCode: nil
            )
        case "edit" where path != nil:
            return .diff(title: path ?? name, files: [FileDiff(
                path: path ?? name,
                oldText: input["old_string"]?.stringValue,
                newText: input["new_string"]?.stringValue ?? ""
            )])
        case "write" where path != nil:
            return .diff(title: path ?? name, files: [FileDiff(path: path ?? name, oldText: nil, newText: input["content"]?.stringValue ?? "")])
        case "grep", "glob":
            return .search(title: input["pattern"]?.stringValue ?? name, lines: [], truncated: false, total: 0)
        case "read", "read_image":
            return .generic(title: path ?? name, kind: "read", detail: nil)
        case "web_fetch":
            return .generic(title: input["url"]?.stringValue ?? name, kind: "fetch", detail: nil)
        case "web_search":
            let queries = (input["queries"]?.arrayValue ?? []).compactMap(\.stringValue)
            return .generic(title: queries.first ?? name, kind: "search", detail: queries.count > 1 ? queries.joined(separator: "\n") : nil)
        default:
            let salient = ["description", "file_path", "path", "pattern", "url", "name"].lazy
                .compactMap { input[$0]?.stringValue }.first { !$0.isEmpty }
            return .generic(title: name, kind: nil, detail: salient)
        }
    }

    /// Fill in a card from its tool's result text: the shell's exit code, the
    /// lines a search found. Other cards show the text as it is.
    static func resultPresentation(_ text: String?, current: ToolPresentation) -> ToolPresentation {
        guard let text else { return current }
        switch current {
        case .terminal(let command, let cwd, let output, _):
            return .terminal(command: command, cwd: cwd, output: output, exitCode: exitCode(in: text))
        case .search(let title, _, _, _):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            return .search(title: title, lines: lines, truncated: false, total: lines.count)
        default:
            return current
        }
    }

    /// The `[exit code: N]` marker dsh's shell tool ends its result with.
    static func exitCode(in text: String) -> Int? {
        guard let range = text.range(of: #"\[exit code: (-?\d+)\]"#, options: [.regularExpression, .backwards]) else { return nil }
        return Int(text[range].dropFirst("[exit code: ".count).dropLast())
    }
}
