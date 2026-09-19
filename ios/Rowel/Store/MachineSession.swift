/// Everything the app knows about one connected machine.
///
/// One of these per paired Mac. It owns the tunnel, consumes its signal stream,
/// and keeps the session list and the open conversations in step with what the
/// machine says. The views read it and never touch the tunnel directly.
///
/// The refresh policy is the interesting part. A phone loses its connection
/// constantly — the radio sleeps, the network changes, the app is suspended — so
/// "reconnected" cannot mean "start over". The Bridle replays the gap by
/// sequence number, which covers almost every drop; only when the replay buffer
/// has overflowed (`resync`) does this refetch, and then it refetches exactly
/// what is on screen rather than everything.

import Foundation
import Observation

/// Messages per history page.
///
/// dsh defaults to 50, and a page is bounded by messages but carries the whole
/// raw event range they span — which for a streaming-heavy session means tens of
/// thousands of `assistant/chunk` events. The Bridle strips the superseded ones,
/// so 50 would be affordable against a current Bridle; this stays lower anyway,
/// because the app has to survive talking to a Bridle that has not been updated
/// yet, and because 25 messages already overfills a phone screen several times.
private let historyPageSize = 25

/// Messages in the first paint of a blank conversation.
///
/// Small enough to arrive fast on the relay path — measured at roughly a
/// quarter of the full page's bytes and half its round trip on a heavy
/// session, and far better than that on a poor uplink — while still filling a
/// phone screen past its edge. The rest of the page follows immediately.
private let firstPaintMessages = 8

/// How many connection log lines to keep.
///
/// Memory only, never written to disk: the log exists so a failure can be read
/// off the phone that had it, not so it can be studied later, and a file would
/// turn a diagnostic aid into something the privacy page has to account for.
/// A hundred lines is several reconnect cycles, which is as far back as any of
/// this is useful.
private let connectionLogLimit = 100

@MainActor
@Observable
public final class MachineSession {
    public let machine: PairedMachine
    public let tunnel: Tunnel
    public let harness: Harness

    public private(set) var status: TunnelStatus = .idle
    /// What the connection has been doing, oldest first. See `ConnectionNote`.
    public private(set) var notes: [ConnectionNote] = []
    /// Every conversation on the machine, newest first, subagents excluded.
    public private(set) var sessions: [SessionSummary] = []
    /// The machine's sidebar groups, empty when it has none or cannot say.
    ///
    /// Empty is not an error state and is never treated as one — see
    /// `refreshWorkspaces` — because the list screen has to work identically on
    /// a machine that has never made a workspace and on one whose dsh is too
    /// old to have the call.
    public private(set) var workspaces: [Workspace] = []
    /// Whether this machine has *ever* answered `workspace.list`.
    ///
    /// The distinction `workspaces.isEmpty` cannot make: a machine with no
    /// groups yet and a machine that has never heard of them look identical in
    /// the list, but only the first one can be offered a "make this folder a
    /// workspace" button that will work.
    ///
    /// Only a success sets it, and nothing clears it. A failure could be an old
    /// dsh answering 404, or the tunnel dropping mid-call, and the two arrive
    /// indistinguishable — so the app never concludes "this machine cannot
    /// group" from a failure, it simply keeps not knowing.
    public private(set) var canGroup = false
    /// Conversations the machine has filed away.
    ///
    /// Kept because `session.list` does not filter them: on this machine
    /// archiving is a sidebar act, the log stays exactly where it was, and
    /// hiding the row is the client's job. Without this the archive button
    /// worked for about a second and then the conversation came back.
    public private(set) var archivedSessionIds: Set<String> = []
    /// Which of those groups are folded shut, remembered between launches.
    public let folds: GroupFolds
    /// What the machine says about itself.
    public private(set) var machineInfo: MachineDescription?
    /// Set when the harness itself is down even though the tunnel is up. The
    /// distinction matters: one is "your Mac is asleep", the other is "dsh isn't
    /// running", and they need different words and different fixes.
    public private(set) var harnessDetail: String?
    /// The six-digit number to compare with the Mac, for a typed-code pairing.
    public private(set) var confirmation: String?
    /// Tools waiting on a decision, by session.
    public private(set) var approvals: [String: ApprovalRequest] = [:]
    /// Questions waiting on an answer, by session.
    public private(set) var questions: [String: QuestionRequest] = [:]
    /// The last thing that went wrong, for a transient banner.
    public var problem: String?
    /// True while the session list is being fetched.
    public private(set) var listing = false
    /// Whether `session.list` has ever completed this run, success or not.
    ///
    /// What separates "the list is still on its way" from "the list is empty".
    /// Without it the moment between coming online and the first page landing
    /// renders as a verdict — "no conversations yet" or worse — for a machine
    /// that has sixty.
    public private(set) var everListed = false
    /// Whether the machine has said anything about dsh yet.
    ///
    /// The status arrives with the `ready` frame, milliseconds after the
    /// handshake — but a render can land in those milliseconds, and until it
    /// does the app has no claim to make about dsh either way.
    public private(set) var harnessKnown = false
    /// Which dsh this machine's Bridle fronts, as of the last ready this app
    /// session saw. Survives a disconnect on purpose: the rescue card needs
    /// the home path precisely when the machine is unreachable. The detail
    /// page shows the port only while online — staleness is a display rule,
    /// not a reason to burn the hint.
    public private(set) var harnessInfo: HarnessInfo?
    /// A one-off note that the route changed, shown briefly then cleared.
    public private(set) var routeChange: String?
    /// Distinguishes the timer that should clear the note from an older one.
    private var routeChangeToken: UUID?
    /// Called when the machine reports where it can be dialled directly now,
    /// so the owner can persist the addresses for the next cold start.
    public var learnedDirect: (([String]) -> Void)?
    /// True while the workspace list is being fetched.
    private var listingWorkspaces = false
    /// Set when a host frame arrived while that fetch was in flight.
    private var workspacesStale = false

    /// What a new conversation starts on, when the person has stated one.
    ///
    /// dsh has no such setting of its own — it routes a fresh session to
    /// whichever provider happens to be first, which on a machine with more
    /// than one configured is a coin toss, and on a machine whose first
    /// provider has no API key is simply broken. Stating it once here is the
    /// difference between "new conversation" working and needing two taps of
    /// repair every time.
    public private(set) var defaultModel: ModelOption?

    private var conversations: [String: Conversation] = [:]
    private var pump: Task<Void, Never>?
    private let notifier: Notifier
    private let defaults: UserDefaults

    /// - Parameter transport: what the harness calls go down. Defaults to this
    ///   machine's own tunnel; tests pass a stub so the write paths — which are
    ///   nearly all rollback — can be made to fail on demand.
    public init(
        machine: PairedMachine,
        identity: StaticKeyPair,
        deviceName: String,
        clientVersion: String,
        pairingToken: String?,
        notifier: Notifier,
        defaults: UserDefaults = .standard,
        transport: (any HarnessTransport)? = nil
    ) {
        self.machine = machine
        self.notifier = notifier
        self.defaults = defaults
        folds = GroupFolds(machineId: machine.id, defaults: defaults)
        if let data = defaults.data(forKey: MachineSession.defaultModelKey(machine.id)) {
            defaultModel = try? JSONDecoder().decode(ModelOption.self, from: data)
        }
        tunnel = Tunnel(
            bundle: machine.reconnectBundle,
            identity: identity,
            deviceName: deviceName,
            clientVersion: clientVersion,
            pairingToken: pairingToken
        )
        harness = Harness(transport: transport ?? tunnel)
    }

    // MARK: - Lifecycle

    public func start() {
        guard pump == nil else { return }
        pump = Task { [tunnel] in
            let stream = await tunnel.signals()
            await tunnel.start()
            for await signal in stream {
                if Task.isCancelled { return }
                self.receive(signal)
            }
        }
    }

    public func stop() {
        // Text that already arrived is folded before the door closes, so
        // stopping on a stream costs the transcript nothing.
        flushHeld()
        pump?.cancel()
        pump = nil
        Task { [tunnel] in await tunnel.stop() }
    }

    /// Reconnect now rather than waiting out the backoff.
    public func poke() {
        Task { [tunnel] in await tunnel.poke() }
    }

    /// Change what this device is called on the machine's paired list.
    public func rename(device name: String) {
        Task { [tunnel] in await tunnel.rename(to: name) }
    }

    public var isOnline: Bool {
        if case .online = status { return true }
        return false
    }

    public var harnessReachable: Bool {
        if case .online(_, _, let up) = status { return up }
        return false
    }

    public var carrier: Carrier? {
        if case .online(let carrier, _, _) = status { return carrier }
        return nil
    }

    // MARK: - Signals

    private func receive(_ signal: TunnelSignal) {
        switch signal {
        case .status(let value):
            let wasOnline = isOnline
            let wasCarrier = carrier
            status = value
            if case .online = value, !wasOnline {
                Task { await self.refreshSessions() }
            }
            // Old evidence may not testify about a new outage: `dshReachable`
            // was a fact about a tunnel that no longer exists, and a stale
            // "dsh isn't running" would steer the offline screen to the wrong
            // tier of diagnosis.
            if wasOnline, !isOnline {
                harnessKnown = false
                harnessDetail = nil
            }
            // A route that changes under a live connection is worth one line.
            // The chip's icon changes too, but an icon swapping while nobody
            // was looking at it explains nothing; this says what happened and
            // then gets out of the way. Only a change *between* two live
            // carriers — coming online is not a switch.
            if let now = carrier, let before = wasCarrier, now != before {
                routeChange = now == .lan
                    ? "Now connected directly over Wi-Fi"
                    : "Wi-Fi is gone — back on the relay"
                let token = UUID()
                routeChangeToken = token
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard let self, self.routeChangeToken == token else { return }
                    self.routeChange = nil
                }
            }
        case .event(let frame):
            switch frame.stream {
            case .mux: handleMux(frame.frame)
            case .host: handleHost(frame.frame)
            }
        case .resync(let from):
            // The gap was too big to replay. Everything on screen is now
            // suspect, so refetch it — and only it.
            _ = from
            Task {
                await self.refreshSessions()
                for conversation in self.conversations.values {
                    await self.loadHistory(conversation, reset: true)
                }
            }
        case .harness(let reachable, let detail):
            harnessKnown = true
            harnessDetail = reachable ? nil : (detail ?? "dsh isn’t running on that Mac.")
        case .handshake(let number, let host, let harness, let direct):
            confirmation = number.isEmpty ? nil : number
            harnessInfo = harness
            if let host, let described = MachineDescription(host) {
                machineInfo = described
            }
            if let direct { learnedDirect?(direct) }
        case .note(let entry):
            notes.append(entry)
            if notes.count > connectionLogLimit {
                notes.removeFirst(notes.count - connectionLogLimit)
            }
        }
    }

    private func handleMux(_ frame: JSONValue) {
        // The Bridle forwards the harness's `server-request` envelope verbatim,
        // because the rpcId inside it is what an answer has to echo.
        let rpcId = frame["rpcId"]?.stringValue ?? ""
        let payload = frame["payload"] ?? frame
        guard let type = payload["type"]?.stringValue else { return }
        let sessionId = payload["sessionId"]?.stringValue ?? ""
        switch type {
        case "session/event":
            guard let event = payload["event"] else { return }
            // Streamed chunks are held and folded together — see `hold`. Anything
            // else applies at once, and only after the chunks before it: the fold
            // reads events in order, and the message that ends a step must not
            // overtake the chunks that built it.
            if event["type"]?.stringValue == "assistant/chunk" {
                hold(event, view: payload["view"], sessionId: sessionId)
                return
            }
            flushHeld()
            existing(sessionId)?.apply(event: event, view: payload["view"])
            touch(sessionId, event: event)
        case "approval/requested":
            let request = ApprovalRequest(
                id: rpcId,
                sessionId: sessionId,
                approvalId: payload["approvalId"]?.stringValue ?? "",
                toolName: payload["toolName"]?.stringValue ?? "a tool",
                reason: payload["reason"]?.stringValue,
                at: Date()
            )
            approvals[sessionId] = request
            notifier.approval(request, machine: machine.name, title: title(of: sessionId))
        case "approval/resolved":
            approvals[sessionId] = nil
        case "question/requested":
            let items = (payload["questions"]?.arrayValue ?? []).compactMap(MachineSession.question)
            guard !items.isEmpty else { return }
            let request = QuestionRequest(id: rpcId, sessionId: sessionId, items: items, at: Date())
            questions[sessionId] = request
            notifier.question(request, machine: machine.name, title: title(of: sessionId))
        case "question/resolved":
            questions[sessionId] = nil
        case "session/queue":
            existing(sessionId)?.applyQueue(payload["items"]?.arrayValue ?? [])
        case "session/projection":
            guard let key = payload["key"]?.stringValue else { return }
            let value = payload["value"] ?? .null
            let seq = payload["seq"]?.intValue ?? 0
            existing(sessionId)?.applyProjection(key: key, value: value, seq: seq)
            if key == "title", let title = value.stringValue {
                update(sessionId) { $0.title = title }
            }
        case "stream/error":
            problem = payload.path("error", "message")?.stringValue
        default:
            // `session/subscribed`, `session/jobs`, and anything a plugin adds.
            break
        }
    }

    // MARK: - Streaming

    /// Streamed chunks waiting for the next flush, in arrival order.
    private var held: [(event: JSONValue, view: JSONValue?, sessionId: String)] = []
    /// The flush already scheduled, if any. One at a time, so the cadence is the
    /// interval rather than the arrival rate.
    private var flushing: Task<Void, Never>?

    /// How long streamed chunks are held before being folded together.
    ///
    /// One frame at 30 Hz. Short enough that text still reads as continuous,
    /// long enough that the transcript changes at a rate a screen can show.
    private static let flushInterval = Duration.milliseconds(33)

    /// Hold one streamed chunk until the next flush.
    ///
    /// A model emits chunks far faster than a screen refreshes — two hundred a
    /// second is ordinary, and the harness in the field reports was doing
    /// exactly that. Folded one at a time, each chunk is a change to the
    /// observable transcript, and `@Observable` turns each change into a SwiftUI
    /// update pass: the streaming bubble is re-parsed and re-laid-out for every
    /// token. Measured on the starvation rig (condition K: 200 chunks a second
    /// into a 190 KB open bubble) that cost 42% of all frames, and a TestFlight
    /// build was killed by iOS for spending more than its ten-second scene-update
    /// allowance inside `AttributeGraph`.
    ///
    /// Holding them for one frame changes nothing about the result: the fold is
    /// order-preserving and `Conversation.apply(event:)` is additive, so a batch
    /// folded at once is the same transcript as the chunks folded one by one.
    private func hold(_ event: JSONValue, view: JSONValue?, sessionId: String) {
        held.append((event: event, view: view, sessionId: sessionId))
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: MachineSession.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flushHeld()
        }
    }

    /// Fold everything held, now. Also called before any event that is not a
    /// chunk, so a stream can never be applied out of order.
    private func flushHeld() {
        flushing?.cancel()
        flushing = nil
        guard !held.isEmpty else { return }
        let batch = held
        held = []
        for entry in batch {
            // No `touch`: it answers to `user/message`, and a chunk is never one.
            existing(entry.sessionId)?.apply(event: entry.event, view: entry.view)
        }
    }

    private func handleHost(_ frame: JSONValue) {
        let payload = frame["payload"] ?? frame
        guard let type = payload["type"]?.stringValue else { return }
        let sessionId = payload["sessionId"]?.stringValue ?? ""
        switch type {
        case "host/session-added":
            guard !sessions.contains(where: { $0.id == sessionId }) else { return }
            guard var summary = SessionSummary(payload) else { return }
            summary.updatedAt = Date()
            guard !summary.isSubagent else { return }
            sessions.insert(summary, at: 0)
        case "host/session-removed":
            sessions.removeAll { $0.id == sessionId }
            conversations[sessionId] = nil
            approvals[sessionId] = nil
            questions[sessionId] = nil
        case "host/session-status":
            let running = payload["running"]?.boolValue ?? false
            update(sessionId) {
                $0.running = running
                // The added frame fires at creation, so `blank` is always true
                // there; a session that has started running has been used.
                if running { $0.blank = false }
            }
            existing(sessionId)?.setRunning(running)
            if !running { notifier.finished(machine: machine.name, title: title(of: sessionId)) }
        case "host/agent-error":
            let message = payload["message"]?.stringValue ?? "The agent failed."
            existing(sessionId)?.note(message, kind: .failure)
            if conversations[sessionId] == nil { problem = message }
        case "host/workspace-changed":
            // The frame says a workspace moved, not what it now holds, and
            // membership is the only part of it this app draws. Re-reading the
            // whole list is three items on the wire and cannot drift; patching
            // from a payload whose shape is not pinned down anywhere could.
            Task { await self.refreshWorkspaces() }
        case "host/workspace-removed":
            // Locally first so the section goes on the same frame, then a
            // re-read, because the local half depends on guessing the id field
            // right and the re-read does not.
            if let removed = payload["workspaceId"]?.stringValue {
                workspaces.removeAll { $0.id == removed }
            }
            Task { await self.refreshWorkspaces() }
        case "host/workspace-order-changed":
            // Nothing, on purpose. The sidebar order is a filing decision made
            // at the keyboard; this app sorts its sections by what was touched
            // most recently instead, so there is nothing here to apply.
            break
        case "host/archived-sessions-changed":
            // The whole set, not a delta, so it can be taken as read — and both
            // directions cost nothing, because `sessions` holds everything the
            // machine reported and the archive is applied when the list is
            // arranged. Unarchiving at the keyboard puts the row straight back.
            archivedSessionIds = Set((payload["archivedSessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue })
        case "stream/error":
            problem = payload.path("error", "message")?.stringValue
        default:
            break
        }
    }

    /// Note that a session produced an event, so the list can reorder without
    /// waiting for a refresh.
    private func touch(_ sessionId: String, event: JSONValue) {
        guard event["type"]?.stringValue == "user/message" else { return }
        update(sessionId) {
            $0.updatedAt = Date()
            $0.blank = false
        }
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }), index > 0 else { return }
        let moved = sessions.remove(at: index)
        sessions.insert(moved, at: 0)
    }

    private func update(_ sessionId: String, _ change: (inout SessionSummary) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        change(&sessions[index])
    }

    private func title(of sessionId: String) -> String {
        sessions.first { $0.id == sessionId }?.displayTitle ?? "a conversation"
    }

    private static func question(_ item: JSONValue) -> QuestionItem? {
        guard let id = item["id"]?.stringValue, let question = item["question"]?.stringValue else { return nil }
        let options = (item["options"]?.arrayValue ?? []).compactMap { option -> QuestionOption? in
            guard let label = option["label"]?.stringValue else { return nil }
            return QuestionOption(label: label, description: option["description"]?.stringValue)
        }
        let intent = item["intent"]
        return QuestionItem(
            id: id,
            question: question,
            header: item["header"]?.stringValue,
            detail: item["detail"]?.stringValue,
            options: options,
            multiSelect: item["multiSelect"]?.boolValue ?? false,
            approveLabel: intent?["kind"]?.stringValue == "plan-review" ? intent?["approve"]?.stringValue : nil
        )
    }

    // MARK: - Reads

    /// The conversation for a session, creating and loading it on first ask.
    public func conversation(_ sessionId: String) -> Conversation {
        if let held = conversations[sessionId] { return held }
        let summary = sessions.first { $0.id == sessionId }
        let fresh = Conversation(sessionId: sessionId, title: summary?.title, cwd: summary?.cwd)
        // Set here rather than left to `loadHistory`, which sets it too — but
        // from inside a Task, and until that Task gets a turn the view holds a
        // conversation with no items and no reason given, which is the empty
        // state. Every conversation opened by flashing "Nothing here yet" at
        // the person before its contents arrived.
        fresh.loading = true
        conversations[sessionId] = fresh
        Task { await loadHistory(fresh, reset: false) }
        // Independently of the history: the machine knows which model this
        // session is on before it has ever run one, and a wrong model is worth
        // seeing before spending a turn on it rather than after.
        Task { await loadModel(fresh) }
        // Once, on open. Discovery is the whole point of this list — the
        // commands work today by typing their names — so a failure here is a
        // missing convenience, not a broken session, and is swallowed.
        Task { await loadCommands(fresh) }
        // Once on open, so the menu can say whether there is anything to look
        // at without making someone tap to find out there is not.
        Task { await loadSubagents(fresh) }
        return fresh
    }

    /// Fetch the children of a conversation.
    ///
    /// Called when the sheet opens rather than on a timer: a child list is only
    /// looked at deliberately, and polling it would spend a round trip per
    /// conversation on something usually empty.
    public func loadSubagents(_ conversation: Conversation) async {
        guard let found = try? await harness.subagents(parentSessionId: conversation.sessionId) else { return }
        conversation.subagents = found.children
        conversation.subagentsKnown = found.available
    }

    private func loadCommands(_ conversation: Conversation) async {
        guard let found = try? await harness.skills(sessionId: conversation.sessionId) else { return }
        conversation.commands = found
    }

    private func existing(_ sessionId: String) -> Conversation? {
        conversations[sessionId]
    }

    /// Which workspace a conversation started in this folder would join.
    public func placement(for folder: String?) -> WorkspacePlacement {
        WorkspacePlacement.resolve(path: folder, workspaces: workspaces, grouping: canGroup)
    }

    /// What can be done about a conversation no workspace holds.
    public func filing(for summary: SessionSummary) -> SessionFiling {
        SessionFiling.resolve(summary, workspaces: workspaces, grouping: canGroup)
    }

    /// Fetch the session list.
    public func refreshSessions() async {
        guard !listing else { return }
        listing = true
        defer {
            listing = false
            everListed = true
        }
        // Alongside the session list rather than after it. Two round trips on
        // one tunnel cost about what one does, and the alternative is a list
        // that draws flat and then rearranges itself into sections a beat
        // later, which on the home screen reads as a glitch.
        async let grouping: Void = refreshWorkspaces()
        do {
            let items = try await harness.listSessions()
            sessions = items.filter { !$0.isSubagent }.sorted { $0.updatedAt > $1.updatedAt }
            if machineInfo == nil, let described = try? await harness.describe() {
                machineInfo = MachineDescription(described)
            }
        } catch let error as CallError where error.code == "disconnected" {
            // The reconnect will refresh again. Saying so would be noise.
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not read the conversation list."
        }
        await grouping
    }

    /// Fetch the sidebar groups. Best effort, always.
    ///
    /// Three ways this can fail and none of them is worth a word on screen: dsh
    /// predates `workspace.list` and answers `method-not-found`, the tunnel
    /// dropped between the two calls, or the machine simply has no workspaces.
    /// All three mean the same thing to the person holding the phone — there is
    /// nothing to group by — and the list falls back to the flat one it has
    /// always drawn. A banner here would report a missing convenience as a
    /// broken conversation list.
    ///
    /// A failure keeps whatever was last known rather than clearing it, so one
    /// dropped call on a machine that *does* group cannot flatten the screen
    /// and un-flatten it a second later.
    public func refreshWorkspaces() async {
        guard !listingWorkspaces else {
            // A frame that lands mid-fetch describes a state the in-flight call
            // may have been too early to see, so it books another round rather
            // than being dropped. Dragging a conversation between workspaces on
            // the Mac emits a burst of these; this collapses the burst into two
            // calls instead of one per frame — and, unlike a plain guard, not
            // into one that settles on the state from before the drag.
            workspacesStale = true
            return
        }
        listingWorkspaces = true
        defer { listingWorkspaces = false }
        repeat {
            workspacesStale = false
            guard let answer = try? await harness.listWorkspaces() else { return }
            workspaces = answer.items
            archivedSessionIds = answer.archived
            // Only ever set by a call that came back. See `canGroup`.
            canGroup = true
        } while workspacesStale
    }

    /// Load a conversation's tail page, or reload it after a resync.
    ///
    /// In two stages when the screen is blank. The cost of a history page is
    /// almost all in its size — measured on a heavy session, 25 messages were
    /// 253 KiB after the Bridle's thinning and 1.2s through the relay, while 8
    /// were 69 KiB and 535ms; on a poor uplink the gap is seconds. And what a
    /// person opens a conversation *for* is the last few exchanges. So the
    /// tail arrives first, small enough to paint fast, and the rest of the
    /// page follows behind it while they read — the same prepend the "load
    /// earlier" button does, without the button.
    public func loadHistory(_ conversation: Conversation, reset: Bool) async {
        if reset { conversation.reset() }
        conversation.loading = true
        defer { conversation.loading = false }
        do {
            let blank = conversation.items.isEmpty
            let page = try await harness.history(
                sessionId: conversation.sessionId,
                maxMessages: blank ? firstPaintMessages : historyPageSize
            )
            conversation.absorb(page: page, prepend: false)
            // The top-up happens inside `loading`, so the "load earlier"
            // control stays quiet until the conversation holds the same page
            // it always used to start with.
            if blank, conversation.hasMore, let before = conversation.oldestSeq {
                let rest = try await harness.history(
                    sessionId: conversation.sessionId,
                    beforeSeq: before,
                    maxMessages: historyPageSize - firstPaintMessages
                )
                conversation.absorb(page: rest, prepend: true)
            }
        } catch let error as CallError where error.code == "disconnected" {
            // Same reasoning as the list: the reconnect retries.
        } catch {
            conversation.note((error as? LocalizedError)?.errorDescription ?? "Could not load this conversation.", kind: .failure)
        }
    }

    /// Ask which model this session is on.
    ///
    /// Failure is silent. The header falls back to offering the picker, which is
    /// the same thing this call would have enabled.
    /// Switch a conversation's model, and show it straight away.
    ///
    /// The write lived in the picker, which updated its own copy of the catalog
    /// and nothing else — so the header went on naming the previous model until
    /// the *next turn ran*, because `modelName` is only otherwise set from a
    /// `request/header` event. Choosing a model and being told you had not is
    /// the kind of thing that gets a person to choose it twice.
    ///
    /// Applied locally on success rather than waited for: the machine accepted
    /// the call, and the next `request/header` will confirm it. Nothing is
    /// assumed on failure.
    ///
    /// - Returns: nil on success, otherwise what to tell the person.
    public func selectModel(sessionId: String, option: ModelOption, effort: String?) async -> String? {
        do {
            try await harness.selectModel(sessionId: sessionId, option: option, reasoningEffort: effort)
            conversation(sessionId).setModel(option.name)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "That model couldn’t be selected."
        }
    }

    private func loadModel(_ conversation: Conversation) async {
        guard let catalog = try? await harness.models(sessionId: conversation.sessionId) else { return }
        conversation.setModel(catalog.current?.name)
    }

    /// Load the page before what is held.
    public func loadOlder(_ conversation: Conversation) async {
        guard conversation.hasMore, let before = conversation.oldestSeq, !conversation.loading else { return }
        conversation.loading = true
        defer { conversation.loading = false }
        do {
            let page = try await harness.history(sessionId: conversation.sessionId, beforeSeq: before, maxMessages: historyPageSize)
            conversation.absorb(page: page, prepend: true)
        } catch {
            // Scrolling back is optional. A failure leaves what is on screen
            // intact and the person can pull again.
        }
    }

    // MARK: - Writes

    /// Send a message, showing it immediately.
    /// Send a message.
    ///
    /// - Parameter steer: interrupt the running turn instead of waiting for it.
    ///   Defaults to queueing, which is what dsh's own client does and the safer
    ///   of the two: steering cuts into work already in progress, and a person
    ///   typing a follow-up while the agent is mid-thought usually means "next",
    ///   not "stop what you are doing". `promote` is how they say the other one.
    ///
    ///   Queueing on an *idle* session is not a stall — dsh claims it and opens
    ///   a turn straight away, which was worth checking rather than assuming.
    public func send(sessionId: String, text: String, images: [PromptImage] = [], steer: Bool = false) async {
        let conversation = conversation(sessionId)
        // Where the optimistic copy goes depends on where the message is
        // actually going. A steer, or a send to an idle session, is claimed
        // immediately — the transcript is the truth about it. A queued send to
        // a *running* session is not said to the model at all yet, and showing
        // it as a bubble puts two contradictory claims on one screen: the
        // transcript reading "delivered" while the queue strip below offers to
        // promote or withdraw the very same words. It waits where it actually
        // is — at the bottom, in the strip — and enters the transcript when
        // the machine's own `user/message` says it was heard.
        if !steer && conversation.running {
            let queuedId = "queued-\(UUID().uuidString)"
            conversation.showQueued(text: text, id: queuedId)
            do {
                try await harness.prompt(sessionId: sessionId, text: text, images: images, steer: false)
            } catch {
                conversation.dropQueued(id: queuedId)
                problem = (error as? LocalizedError)?.errorDescription ?? "That message didn’t send."
            }
            return
        }
        let pendingId = "pending-\(UUID().uuidString)"
        conversation.showPending(text: text, id: pendingId)
        do {
            try await harness.prompt(sessionId: sessionId, text: text, images: images, steer: steer)
        } catch {
            conversation.dropPending(id: pendingId)
            problem = (error as? LocalizedError)?.errorDescription ?? "That message didn’t send."
        }
    }

    /// Cut a queued message into the running turn.
    ///
    /// dsh has no "promote" on `session.updateQueue` — it edits and removes —
    /// so this is a remove followed by a steered resend. The order matters: if
    /// the remove fails the message is still queued and nothing was lost, while
    /// the reverse would risk the same text arriving twice.
    public func promote(sessionId: String, item: QueuedMessage) async {
        do {
            try await harness.updateQueue(sessionId: sessionId, itemId: item.id, action: .remove)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That message could not be moved up."
            return
        }
        do {
            try await harness.prompt(sessionId: sessionId, text: item.text, steer: true)
        } catch {
            // Removed and not resent: say so, because the message is now gone
            // from a queue the person was watching and silence would read as
            // "it went through".
            problem = (error as? LocalizedError)?.errorDescription
                ?? "That message left the queue but could not be sent. Send it again."
        }
    }

    public func cancel(sessionId: String) async {
        do { try await harness.cancel(sessionId: sessionId) } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not stop the agent."
        }
    }

    /// What new conversations on this machine start as. Nil until read.
    public private(set) var accessDefault: PermissionChoice?

    /// Read the machine's access default.
    public func refreshAccessDefault() async {
        accessDefault = (try? await harness.permissionDefault()) ?? accessDefault
    }

    /// Change how much the agent may touch, machine-wide.
    ///
    /// Returns the failure to show inline rather than setting `problem`: this is
    /// a choice made inside one sheet, and a banner over the whole app would put
    /// the message somewhere other than the control that produced it. Nothing is
    /// applied locally on success — the machine answers with a `permissions`
    /// projection, and letting that be the only source of truth means the
    /// checkmark cannot disagree with the machine.
    ///
    /// - Returns: nil on success, otherwise what to tell the person.
    public func setPermission(_ preset: String) async -> String? {
        do {
            try await harness.setPermission(preset)
            // The machine accepted the write, so reflect it. Nothing else will:
            // the per-session projection does not move for a settings change,
            // which is exactly what made the old control look dead.
            accessDefault = PermissionChoice(.object([
                "currentValue": .string(preset),
                "options": .array((accessDefault?.options ?? []).map {
                    .object(["value": .string($0.value), "name": .string($0.name)])
                }),
            ])) ?? accessDefault
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "The Mac would not change the access mode."
        }
    }

    /// Change how much *this* conversation's agent may touch.
    ///
    /// The session-scoped counterpart of `setPermission`, and a different dsh
    /// path: the machine's `/permission` command appends `permission/preset`
    /// plus whichever knobs that preset changes to **this session's own log**,
    /// so the conversation runs differently from here on while every other one
    /// is left where it was. That is the whole reason the command exists — the
    /// machine-wide default cannot reach a conversation that already started.
    ///
    /// Nothing is applied locally. The command moves the session's `permissions`
    /// projection, which pushes to this app like any other projection, and
    /// letting that be the only source of truth means the checkmark cannot
    /// disagree with the machine about what the agent is allowed to do.
    ///
    /// - Returns: nil on success, otherwise what to tell the person.
    public func setSessionPermission(sessionId: String, preset: String) async -> String? {
        do {
            let ran = try await harness.command(sessionId: sessionId, line: "/permission \(preset)")
            guard ran != nil else {
                return "This Mac’s dsh has no /permission command, so a running conversation cannot be changed here."
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? "The Mac would not change this conversation’s access mode."
        }
    }

    /// Start a conversation and return its id.
    /// Choose what new conversations start on. `nil` hands the choice back to
    /// the machine.
    public func setDefaultModel(_ option: ModelOption?) {
        defaultModel = option
        let key = MachineSession.defaultModelKey(machine.id)
        if let option, let data = try? JSONEncoder().encode(option) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// Scoped per machine: two Macs rarely have the same providers configured,
    /// and a model id from one is meaningless on the other.
    private static func defaultModelKey(_ machineId: String) -> String {
        "rowel.defaultModel.\(machineId)"
    }

    /// The ways this machine can start a conversation, fetched once per run.
    ///
    /// Empty until asked and empty on an older dsh, and the picker treats both
    /// the same way: no choice to offer, so no control drawn. The default the
    /// machine would use anyway is not worth a menu of one.
    public private(set) var presets: [AgentPreset] = []

    public func loadPresets() async {
        guard presets.isEmpty else { return }
        presets = (try? await harness.presets()) ?? []
    }

    /// Everything mounted in the machine's dsh. Fetched fresh each time — the
    /// list changes when the person edits their profile, and staleness here
    /// would misreport exactly the thing someone opens this to check.
    public func plugins() async -> [PluginEntry]? {
        try? await harness.pluginInventory()
    }

    public func createSession(cwd: String?, preset: String? = nil) async -> String? {
        do {
            let id = try await harness.createSession(cwd: cwd, agentPreset: preset)
            if let defaultModel {
                // Best effort. A model that has since been removed from the
                // machine should not stop the conversation from opening; the
                // header states what it actually landed on either way.
                try? await harness.selectModel(sessionId: id, option: defaultModel)
            }
            var summary = SessionSummary(.object([
                "sessionId": .string(id),
                "updatedAt": .number(Date().timeIntervalSince1970 * 1000),
                "running": .bool(false),
                "blank": .bool(true),
            ]))
            summary?.cwd = cwd
            if let summary, !sessions.contains(where: { $0.id == id }) {
                sessions.insert(summary, at: 0)
            }
            await joinWorkspace(id, folder: cwd)
            return id
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not start a conversation."
            return nil
        }
    }

    /// File a just-created conversation under the workspace for its folder.
    ///
    /// A second call rather than creating it with `workspaceId` in the first
    /// place, which the machine also supports. The reason is what happens on a
    /// machine that is *nearly* new enough: a dsh with `workspace.list` but an
    /// older `session.create` would drop the unknown `workspaceId`, fall back to
    /// its own default directory, and start the conversation somewhere else
    /// entirely. Sending the folder is the thing that must not be got wrong;
    /// the grouping is a convenience and can be attempted afterwards, where
    /// failing means an ungrouped conversation rather than one in the wrong
    /// place.
    ///
    /// A folder nothing stands for is claimed on the way, so that there is
    /// something to file the conversation into. The machine's ledger is written
    /// only when a conversation is filed into a workspace, and nothing on the
    /// wire backfills it: a conversation started before its folder had a
    /// workspace is missing from the Mac's sidebar for good. That is the state
    /// this app used to leave behind, one folder at a time — a conversation the
    /// phone seats correctly by working directory and the Mac calls ungrouped.
    /// Claiming at the moment the conversation starts closes it at the source,
    /// and it spends nothing the person has not already decided: they chose this
    /// folder for this conversation. What it costs is a section on the Mac that
    /// nobody made there by hand — a row in a list, removable, with nothing on
    /// disk behind it.
    private func joinWorkspace(_ sessionId: String, folder: String?) async {
        switch placement(for: folder) {
        case .joins(let workspaceId, _):
            await file(sessionId, into: workspaceId)
        case .ungrouped:
            guard let folder, let made = try? await harness.createWorkspace(path: folder) else { return }
            adopt(made.workspace)
            await file(sessionId, into: made.workspace.id)
        case .unknown:
            // The machine has never said it groups, or the folder is the Mac's
            // own default — which cannot be named from here. Either way there is
            // nothing to join and nothing to make.
            break
        }
    }

    /// Write a conversation into its workspace's ledger, best effort.
    private func file(_ sessionId: String, into workspaceId: String) async {
        do {
            try await harness.fileSession(sessionId, into: workspaceId)
            await refreshWorkspaces()
        } catch {
            // Not reported, deliberately, and this used to say "It's under
            // Ungrouped". It no longer is: the board seats a conversation by
            // its working directory whether or not the machine's ledger lists
            // it, so nothing on this phone looks different when this write
            // fails. The only audience left is the Mac's own sidebar, which
            // stays one row short, and an alert about another machine's
            // bookkeeping is not worth interrupting the conversation that
            // just opened.
        }
    }

    /// Branch a conversation and return the new one's id.
    ///
    /// The machine keeps the history up to the branch point, so this is the
    /// "try it the other way without losing this" move — which is worth more on
    /// a phone than at a keyboard, where re-running something is cheap.
    public func fork(sessionId: String) async -> String? {
        do {
            let id = try await harness.fork(sessionId: sessionId)
            await refreshSessions()
            return id
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not branch the conversation."
            return nil
        }
    }

    /// Take a conversation out of the list.
    ///
    /// Archived locally before the machine confirms, because the list is the
    /// screen the person is looking at and a row that lingers for a round trip
    /// reads as a failed tap. A refusal puts it back.
    ///
    /// Marked rather than removed. `session.list` keeps answering with archived
    /// conversations — the machine treats hiding them as the client's job — so
    /// dropping the row here would only have held until the next refresh, which
    /// is exactly what used to happen. The set is what the list is filtered by,
    /// and it is also why unarchiving at the keyboard needs no refetch.
    public func archive(sessionId: String) async {
        let held = archivedSessionIds
        archivedSessionIds.insert(sessionId)
        do {
            try await harness.archive(sessionId: sessionId)
        } catch {
            archivedSessionIds = held
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not archive the conversation."
        }
    }

    // MARK: - Workspaces

    /// Take the machine's word for a workspace it has just answered with.
    ///
    /// A successful write is also the machine saying it groups, which is what
    /// `canGroup` records. Applied locally rather than waited on because the
    /// board reads this list, and a conversation filed into a workspace the app
    /// does not hold yet would sit in the leftovers for a round trip.
    private func adopt(_ workspace: Workspace) {
        canGroup = true
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            // The machine prepends, and matching that keeps the two in step
            // until the next read — which is only cosmetic here, since the
            // sections are ordered by activity rather than by this list.
            workspaces.insert(workspace, at: 0)
        }
    }

    /// Claim a folder as a workspace.
    ///
    /// Nothing is applied before the machine answers, unlike the rest of the
    /// writes here. There is nothing honest to apply: only the machine can say
    /// what id the workspace has, whether it already existed, and — the part
    /// that would make an optimistic row a lie — that it starts *empty*.
    /// Claiming a folder does not gather up the conversations already running
    /// in it; it decides where the next one goes.
    ///
    /// The failure comes back rather than going to `problem`, following
    /// `setPermission`: this is done from inside the folder sheet, and the
    /// banner lives on the screen behind it, so a message sent there would be
    /// delivered somewhere nobody can see.
    ///
    /// - Returns: nil on success, otherwise what to tell the person.
    @discardableResult
    public func createWorkspace(path: String) async -> String? {
        do {
            let made = try await harness.createWorkspace(path: path)
            adopt(made.workspace)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription
                ?? "The Mac wouldn’t make that folder a workspace."
        }
    }

    /// Give a workspace a different name.
    ///
    /// Applied locally first: this is a header on the screen being looked at,
    /// and the round trip is long enough to read as a tap that missed. A refusal
    /// — a blank name, or one another workspace already has — puts the old name
    /// back and shows what the machine said, which names the clash.
    @discardableResult
    public func renameWorkspace(_ workspaceId: String, title: String) async -> Bool {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked here as well as on the machine, so the empty case costs
        // nothing and says something better than a schema message would.
        guard !wanted.isEmpty else {
            problem = "A workspace needs a name."
            return false
        }
        let held = workspaces
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            workspaces[index].title = wanted
        }
        do {
            let renamed = try await harness.renameWorkspace(id: workspaceId, title: wanted)
            if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
                workspaces[index] = renamed
            }
            return true
        } catch {
            workspaces = held
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not rename that workspace."
            return false
        }
    }

    /// Stop grouping by a folder.
    ///
    /// The section goes immediately and its conversations fall into the
    /// leftovers, which is exactly what the machine does — see
    /// `Harness.deleteWorkspace` for what survives, which is everything except
    /// the grouping. A refusal puts the section back where it was.
    @discardableResult
    public func deleteWorkspace(_ workspaceId: String) async -> Bool {
        let held = workspaces
        workspaces.removeAll { $0.id == workspaceId }
        do {
            try await harness.deleteWorkspace(id: workspaceId)
            return true
        } catch {
            workspaces = held
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not remove that workspace."
            return false
        }
    }

    public func rename(sessionId: String, title: String) async {
        do {
            try await harness.rename(sessionId: sessionId, title: title)
            update(sessionId) { $0.title = title }
            existing(sessionId)?.applyProjection(key: "title", value: .string(title), seq: Int.max)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not rename that conversation."
        }
    }

    public func answer(approval: ApprovalRequest, allow: Bool) async {
        // Clear first. The machine confirms with `approval/resolved`, but the
        // button must stop looking pressable the instant it is tapped.
        approvals[approval.sessionId] = nil
        do {
            try await harness.answerApproval(approval, allow: allow)
        } catch {
            approvals[approval.sessionId] = approval
            problem = (error as? LocalizedError)?.errorDescription ?? "That answer didn’t reach the Mac."
        }
    }

    public func answer(question: QuestionRequest, answers: [String: QuestionAnswer]) async {
        questions[question.sessionId] = nil
        do {
            try await harness.answerQuestion(question, answers: answers)
        } catch {
            questions[question.sessionId] = question
            problem = (error as? LocalizedError)?.errorDescription ?? "That answer didn’t reach the Mac."
        }
    }
}

/// Which sections of the conversation list are folded shut.
///
/// Remembered, because a fold that resets every launch is not a fold — someone
/// who collapsed the workspace holding 40 finished conversations did so to stop
/// scrolling past them, and doing it again tomorrow morning is the app failing
/// to listen.
///
/// Three states per section, not two. "Never said" has to be distinguishable
/// from "said open", or the default — open the most recent one — would silently
/// re-close a section the person deliberately opened as soon as something else
/// became more recent.
///
/// Kept out of `MachineSession` so it can be tested without a tunnel, and given
/// its own `UserDefaults` so a test can hand it a throwaway suite.
@MainActor
@Observable
public final class GroupFolds {
    private let machineId: String
    private let defaults: UserDefaults
    private var remembered: [String: Bool]

    public init(machineId: String, defaults: UserDefaults = .standard) {
        self.machineId = machineId
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: GroupFolds.key(machineId)) ?? [:]
        remembered = stored.compactMapValues { $0 as? Bool }
    }

    /// Whether a section is open, falling back to the arrangement's suggestion
    /// when nobody has expressed a view.
    public func isOpen(_ groupId: String, unlessRemembered fallback: Bool) -> Bool {
        remembered[groupId] ?? fallback
    }

    public func set(_ groupId: String, open: Bool) {
        remembered[groupId] = open
        defaults.set(remembered, forKey: GroupFolds.key(machineId))
    }

    /// Scoped per machine: workspace ids are the machine's, and two Macs paired
    /// with the same phone share nothing but the phone.
    ///
    /// One key holding a dictionary rather than a key per workspace, so that
    /// removing a machine's memory is one call and so that a workspace deleted
    /// on the Mac leaves one dead entry rather than one dead default.
    private static func key(_ machineId: String) -> String {
        "rowel.groupFolds.\(machineId)"
    }
}

// MARK: - Test seam

extension MachineSession {
    /// Feed one tunnel signal, as the pump does.
    ///
    /// The interrupts — an approval, a question — arrive only this way and
    /// only from a machine that has stopped to ask, which is a state no test
    /// could reach through the public surface. They went untested for exactly
    /// that reason, and the first time one was needed in the field it did not
    /// appear.
    func receiveForTesting(_ signal: TunnelSignal) {
        receive(signal)
    }
}
