/// One session's transcript, folded from its event log.
///
/// The harness never sends a rendered view. It sends the same append-only event
/// log it persists, and every client folds it into whatever it wants to show.
/// That is what lets this app render a conversation started in the web UI, and
/// what lets it resume one mid-stream after a tunnel drop: the fold is a pure
/// function of the events, so replaying the gap converges on the same state.
///
/// Two rules the fold depends on:
///
/// - **Events are numbered and ordered.** `seq` dedupes, so a history page that
///   overlaps the live stream cannot double-render a message.
/// - **Chunks precede their message.** `assistant/chunk` builds a bubble token by
///   token; `assistant/message` replaces it with the assembled content. A tail
///   history page carries the in-flight chunks of an unfinished message, so an
///   app that opens mid-turn sees the same partial text the web UI does.

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
    /// Skills this session offers, from `skill.list`. Fetched once; skills do
    /// not appear mid-sentence, and a request per keystroke would.
    public var skills: [SlashCommand] = []
    /// Commands the *machine* will run for this session, from `commands/list`.
    ///
    /// Kept apart from the skills because sending them is a different act: a
    /// skill is text the model reads, a command is handed to `commands/execute`.
    /// `machineLine(for:)` is the whole of that decision.
    public var machineCommands: [SlashCommand] = []

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

    /// True while the first history page is loading.
    public var loading = false
    /// True when older pages exist.
    public private(set) var hasMore = false
    /// Lowest event sequence held, the cursor for loading older pages.
    public private(set) var oldestSeq: Int?
    /// True once a history page has landed, so the view can tell empty from unloaded.
    public private(set) var loaded = false

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
    /// Optimistic bubbles, by id, holding the text they were shown with.
    ///
    /// The harness mints its own id for a message, so the echoed `user/message`
    /// can never be matched to the bubble by id. Without this the optimistic
    /// copy stays on screen and every single message appears twice.
    private var pending: [(id: String, text: String)] = []

    public init(sessionId: String, title: String? = nil, cwd: String? = nil) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
    }

    // MARK: - History

    /// Replace everything with a freshly loaded tail page.
    public func reset() {
        items = []
        assistantIndex = [:]
        toolIndex = [:]
        seen = []
        projectionSeq = [:]
        pending = []
        oldestSeq = nil
        loaded = false
    }

    /// Fold one history page. `prepend` is true for an older page.
    public func absorb(page: JSONValue, prepend: Bool) {
        let entries = page["events"]?.arrayValue ?? []
        if prepend {
            // Older events belong before everything already held. Folding them
            // into a scratch conversation and splicing the result keeps the fold
            // itself append-only, which is the only order it is correct in.
            let older = Conversation(sessionId: sessionId)
            older.absorb(page: page, prepend: false)
            let carried = older.items
            items.insert(contentsOf: carried, at: 0)
            reindex()
            seen.formUnion(older.seen)
        } else {
            for entry in entries {
                guard let event = entry["event"] else { continue }
                apply(event: event, view: entry["view"])
            }
        }
        if let first = entries.first?["event"]?["seq"]?.intValue {
            oldestSeq = min(oldestSeq ?? first, first)
        }
        // Whichever page just landed is the one that knows whether anything is
        // left: the tail page for a fresh load, the older page for a scroll-back.
        hasMore = page["hasMore"]?.boolValue ?? false
        if let projections = page["projections"] {
            absorbProjections(projections)
        }
        loaded = true
    }

    /// Apply the projection baseline that rides the tail history page.
    public func absorbProjections(_ block: JSONValue) {
        let asOf = block["asOfSeq"]?.intValue ?? 0
        for (key, value) in block["values"]?.objectValue ?? [:] {
            applyProjection(key: key, value: value, seq: asOf)
        }
    }

    /// Apply one `session/projection` frame.
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
            permissions = PermissionChoice(value)
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
    public func apply(event: JSONValue, view: JSONValue?) {
        guard let type = event["type"]?.stringValue else { return }
        let seq = event["seq"]?.intValue ?? 0
        guard seq == 0 || seen.insert(seq).inserted else { return }
        let at = Date(timeIntervalSince1970: (event["time"]?.doubleValue ?? 0) / 1000)
        let data = event["data"] ?? .emptyObject

        switch type {
        case "turn/start":
            running = true
        case "turn/end":
            running = false
            completeStreaming()
            if let reason = data["reason"]?["kind"]?.stringValue, reason != "success", reason != "completed" {
                let detail = data["reason"]?["message"]?.stringValue ?? data["reason"]?["failure"]?["message"]?.stringValue
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
        case "assistant/chunk":
            applyChunk(data, seq: seq, at: at)
        case "assistant/message":
            finishAssistant(data, seq: seq, at: at)
        case "tool/call":
            openToolCard(data, view: view, at: at)
        case "tool/result":
            closeToolCard(data, view: view, at: at)
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
            // Log-only events (`step/start`, `request/context`, `session/end-seed`)
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
        // This is the real copy of something already on screen optimistically.
        // Matching is by text rather than by id because the harness mints the id
        // and the app never learns which of its sends it belongs to; the oldest
        // outstanding send with the same body is the right one, since a person
        // cannot send two messages out of order.
        clearPending(matching: text)
        // And reconcile the queue strip the same way. dsh does send an empty
        // `session/queue` snapshot when it claims a message, but that snapshot
        // is a transient — it rides the live stream, there is no call to
        // re-ask, and one missed reconnect window leaves the strip offering to
        // promote a message the transcript shows already answered. The
        // machine speaking the message *is* the claim, so hearing it fold in
        // is enough to retire the strip's copy. One entry, oldest first, for
        // the same reason `clearPending` matches that way.
        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let claimed = queue.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == spoken }) {
            queue.remove(at: claimed)
        }
        let id = message["id"]?.stringValue ?? "u\(seq)"
        append(.user(UserTurn(id: id, text: text, images: images, synthetic: false, at: at)))
    }

    /// Remove the oldest optimistic bubble whose text matches.
    private func clearPending(matching text: String) {
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = pending.firstIndex(where: { $0.text == wanted }) else { return }
        let id = pending.remove(at: index).id
        items.removeAll { $0.id == id }
        reindex()
    }

    private func applyChunk(_ data: JSONValue, seq: Int, at: Date) {
        guard let chunk = data["chunk"], let kind = chunk["type"]?.stringValue else { return }
        let turn = data["turn"]?.intValue ?? 0
        let step = data["step"]?.intValue ?? 0
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

    private func openToolCard(_ data: JSONValue, view: JSONValue?, at: Date) {
        guard let callId = data["callId"]?.stringValue else { return }
        let name = data["name"]?.stringValue ?? "tool"
        let arguments = data["arguments"]?.stringValue ?? "{}"
        let presentation = Conversation.callPresentation(view?["view"], for: view?["for"]?.stringValue, name: name, arguments: arguments)
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

    private func closeToolCard(_ data: JSONValue, view: JSONValue?, at: Date) {
        let block = data.path("message", "content")?.arrayValue?.first
        let callId = data.path("message", "source", "callId")?.stringValue
            ?? block?["toolCallId"]?.stringValue
        guard let callId, let index = toolIndex[callId], case .tool(var card) = items[index] else { return }
        card.running = false
        card.finishedAt = at
        card.failed = data["error"] != nil && data["error"]?.isNull == false
            || block?["isError"]?.boolValue == true
        card.resultText = Conversation.plainText(block?["content"]?.arrayValue ?? [])
        if view?["for"]?.stringValue == "result", let result = view?["view"] {
            card.presentation = Conversation.resultPresentation(result, current: card.presentation)
        }
        items[index] = .tool(card)
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

    /// Apply a `session/queue` snapshot. The whole set arrives every time, so
    /// this replaces rather than merges.
    public func applyQueue(_ items: [JSONValue]) {
        queue = items.compactMap { item in
            guard let id = item["id"]?.stringValue else { return nil }
            let text = Conversation.plainText(item.path("message", "content")?.arrayValue ?? [])
            return QueuedMessage(id: id, text: text, placement: item["placement"]?.stringValue ?? "queued")
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

    /// Show a message in the queue strip before the machine has confirmed it.
    ///
    /// The next `session/queue` snapshot replaces the whole array, so this
    /// provisional entry is swapped for the machine's own the moment it
    /// answers — same shape as `showPending`, aimed at the other place.
    public func showQueued(text: String, id: String) {
        queue.append(QueuedMessage(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines), placement: "queued"))
    }

    /// Take back a provisional queue entry whose send failed. A no-op when a
    /// real snapshot has already replaced it, which is the correct outcome:
    /// the machine's word beats the guess.
    public func dropQueued(id: String) {
        queue.removeAll { $0.id == id }
    }

    /// Show a message optimistically, before the machine has logged it. The real
    /// `user/message` event replaces it by id when it arrives.
    public func showPending(text: String, id: String) {
        pending.append((id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        append(.user(UserTurn(id: id, text: text, images: [], synthetic: false, at: Date())))
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

    /// Turn a call-time render intent into a card.
    static func callPresentation(_ view: JSONValue?, for slot: String?, name: String, arguments: String) -> ToolPresentation {
        guard slot == "call", let view, let card = view["card"]?.stringValue else {
            return .generic(title: name, kind: nil, detail: nil)
        }
        let title = view["title"]?.stringValue ?? name
        switch card {
        case "terminal":
            return .terminal(command: title, cwd: view["cwd"]?.stringValue, output: nil, exitCode: nil)
        case "diff":
            return .diff(title: title, files: fileDiffs(view["diffs"]))
        default:
            return .generic(title: title, kind: view["kind"]?.stringValue, detail: detail(from: view["rawInput"]))
        }
    }

    /// Turn a result-time render intent into a card, keeping what the pending
    /// card already established. An omitted `title` means "keep the old one",
    /// which is why this takes the current presentation rather than replacing it
    /// outright.
    static func resultPresentation(_ view: JSONValue, current: ToolPresentation) -> ToolPresentation {
        let card = view["card"]?.stringValue ?? "generic"
        let replacement = view["title"]?.stringValue
        switch card {
        case "terminal":
            var command = replacement ?? ""
            var cwd: String?
            if case .terminal(let existing, let existingCwd, _, _) = current {
                if replacement == nil { command = existing }
                cwd = existingCwd
            }
            return .terminal(
                command: command,
                cwd: cwd,
                output: view["output"]?.stringValue,
                exitCode: view["exitCode"]?.intValue
            )
        case "diff":
            return .diff(title: replacement ?? currentTitle(current), files: fileDiffs(view["diffs"]))
        case "search":
            let title = replacement ?? currentTitle(current)
            if view["shape"]?.stringValue == "paths" {
                let paths = (view["paths"]?.arrayValue ?? []).compactMap { $0.stringValue }
                return .search(
                    title: title,
                    lines: paths,
                    truncated: view["truncated"]?.boolValue ?? false,
                    total: view["total"]?.intValue ?? paths.count
                )
            }
            var lines: [String] = []
            for file in view["files"]?.arrayValue ?? [] {
                let path = file["path"]?.stringValue ?? "?"
                for match in file["matches"]?.arrayValue ?? [] {
                    let number = match["lineNumber"]?.intValue ?? 0
                    let text = match["line"]?.stringValue ?? ""
                    lines.append("\(path):\(number)  \(text)")
                }
            }
            return .search(
                title: title,
                lines: lines,
                truncated: view["truncated"]?.boolValue ?? false,
                total: view["total"]?.intValue ?? lines.count
            )
        case "read":
            let lines = (view["lines"]?.arrayValue ?? []).compactMap { line -> NumberedLine? in
                guard let number = line["number"]?.intValue else { return nil }
                return NumberedLine(number: number, text: line["text"]?.stringValue ?? "")
            }
            return .read(
                path: view["path"]?.stringValue ?? currentTitle(current),
                lines: lines,
                totalLines: view["totalLines"]?.intValue ?? lines.count
            )
        case "web":
            let title = replacement ?? currentTitle(current)
            if view["kind"]?.stringValue == "fetch" {
                let url = view["url"]?.stringValue ?? ""
                let status = view["statusCode"]?.intValue ?? 0
                return .generic(title: title, kind: "fetch", detail: "\(status)  \(url)")
            }
            let sources = (view["sources"]?.arrayValue ?? []).compactMap { source -> String? in
                guard let url = source["url"]?.stringValue else { return nil }
                return source["title"].flatMap { $0.stringValue }.map { "\($0)\n\(url)" } ?? url
            }
            let answer = view["answer"]?.stringValue
            let body = ([answer].compactMap { $0 } + sources).joined(separator: "\n\n")
            return .generic(title: title, kind: "search", detail: body.isEmpty ? nil : body)
        default:
            let content = view["content"]?.arrayValue.map { plainText($0) }
            return .generic(
                title: replacement ?? currentTitle(current),
                kind: currentKind(current),
                detail: content?.isEmpty == false ? content : currentDetail(current)
            )
        }
    }

    private static func currentTitle(_ presentation: ToolPresentation) -> String {
        switch presentation {
        case .generic(let title, _, _): return title
        case .terminal(let command, _, _, _): return command
        case .diff(let title, _): return title
        case .search(let title, _, _, _): return title
        case .read(let path, _, _): return path
        }
    }

    private static func currentKind(_ presentation: ToolPresentation) -> String? {
        if case .generic(_, let kind, _) = presentation { return kind }
        return nil
    }

    private static func currentDetail(_ presentation: ToolPresentation) -> String? {
        if case .generic(_, _, let detail) = presentation { return detail }
        return nil
    }

    private static func fileDiffs(_ value: JSONValue?) -> [FileDiff] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let path = entry["path"]?.stringValue else { return nil }
            return FileDiff(
                path: path,
                oldText: entry["oldText"]?.isNull == false ? entry["oldText"]?.stringValue : nil,
                newText: entry["newText"]?.stringValue ?? ""
            )
        }
    }

    /// A salient input, rendered as text. Tools send either a string or an
    /// object here, and the object form is worth pretty-printing.
    private static func detail(from value: JSONValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
