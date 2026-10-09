/// Everything the app knows about one connected machine.
///
/// One of these per paired Mac. It owns the tunnel, consumes its signal stream,
/// and keeps the session list and the open conversations in step with what the
/// machine says. The views read it and never touch the tunnel directly.
///
/// Everything live arrives on dsh's own streams, passed through by the Bridle
/// (docs/protocol.md §4): `$events` for approvals, questions and the session
/// list, `workspace/follow` for the sidebar, `session/control` for every loaded
/// session's projections, and one `session/follow` per conversation held here.
/// A phone loses its connection constantly, and none of these resume — so each
/// starts with the whole of its state, and on every reconnect they are simply
/// opened again (`attach`) and what they say replaces what was held.

import Foundation
import Observation

/// Messages in a conversation's snapshot, and in each older page.
///
/// dsh defaults to 50. A page is bounded by messages but carries every event
/// in between — a request header with the full tool schemas on every step among
/// them — and all of it crosses the relay. 25 messages already overfill a phone
/// screen several times.
private let followMessages = 25

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
    /// Whether this machine has said anything about its workspaces yet — a
    /// `workspace/follow` baseline, or a workspace write that came back.
    ///
    /// The distinction `workspaces.isEmpty` cannot make: until the machine has
    /// spoken, an empty list means "not known" rather than "none", and a "make
    /// this folder a workspace" button would be a guess. Nothing clears it.
    public private(set) var canGroup = false
    /// Conversations the machine has filed away.
    ///
    /// Kept because `session/list` does not filter them: on this machine
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
    /// Tools waiting on a decision, by session.
    public private(set) var approvals: [String: ApprovalRequest] = [:]
    /// Questions waiting on an answer, by session.
    public private(set) var questions: [String: QuestionRequest] = [:]
    /// The last thing that went wrong, for a transient banner.
    public var problem: String?
    /// True while the session list is being fetched.
    public private(set) var listing = false
    /// Whether `session/list` has ever completed this run, success or not.
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
    /// Whether this connection's streams are open — false from a handshake or
    /// a dsh outage until `attach` runs.
    @ObservationIgnored private var attached = false
    /// The three machine-wide streams of this connection. See `attach`.
    @ObservationIgnored private var machineStreams: [Task<Void, Never>] = []
    /// One `session/follow` per held conversation, by session id.
    @ObservationIgnored private var follows: [String: Task<Void, Never>] = [:]
    /// Who this app is to `$events` on this connection. An answer to an
    /// approval or a question has to name it (docs/dsh-0.2-protocol.md §5.4).
    @ObservationIgnored private var eventsClientId: String?
    /// The list read under way for the current `$events` client, and whether
    /// a list change arrived during it. See `syncList`.
    @ObservationIgnored private var listSync: (generation: Int, dirty: Bool)?
    /// Counts `$events` clients, so a read for an older one cannot land.
    @ObservationIgnored private var listGeneration = 0
    /// Session list reads in flight; `listing` is whether there are any.
    @ObservationIgnored private var reads = 0
    /// Subagents' parents, by child id: from the list, which names a child's
    /// parent, and from the parent's catalog, which also says how it runs.
    /// A child's log is read through its parent, and what it asks for is shown
    /// in the conversation a person is actually looking at.
    @ObservationIgnored private var parents: [String: SubagentParent] = [:]

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
    /// Conversation ids, most recently opened first. The first is the one on
    /// screen; see `conversation(_:)`.
    ///
    /// Not observed — none of this bookkeeping is anything a view draws, and
    /// observing it made a read into a write: `conversation(_:)` updates this
    /// on every call, so a view that asked from its `body` invalidated itself
    /// on every render (`SessionInfoView`, a 36 s freeze on a phone).
    @ObservationIgnored private var recent: [String] = []
    /// How many conversations stay folded in memory. Each keeps a follow open
    /// and folds its live events, so the cost of an unbounded cache is paid in
    /// main-thread work and relay traffic as well as memory.
    private static let heldConversations = 8
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
            guard !Task.isCancelled else { return }
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
        let running = pump
        running?.cancel()
        pump = nil
        // After the pump has wound down, not beside it. Two unordered tasks let
        // a stop that followed a start reach the tunnel first — and the start
        // then brought up a tunnel nobody was reading, redialling forever.
        Task { [tunnel] in
            await running?.value
            await tunnel.stop()
        }
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
            // Old evidence may not testify about a new outage: `dshReachable`
            // was a fact about a tunnel that no longer exists, and a stale
            // "dsh isn't running" would steer the offline screen to the wrong
            // tier of diagnosis.
            if wasOnline, !isOnline {
                harnessKnown = false
                harnessDetail = nil
                attached = false
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
        case .harness(let reachable, let detail):
            harnessKnown = true
            harnessDetail = reachable ? nil : (detail ?? "dsh isn’t running on that Mac.")
            // Every stream ended with `upstream-lost` when dsh went; now that it
            // is back, they are opened again.
            if !reachable {
                attached = false
                // The `$events` client that delivered them is gone with dsh;
                // the next one is re-sent whatever is still waiting.
                approvals = [:]
                questions = [:]
                eventsClientId = nil
            } else if !attached {
                attach()
            }
        case .handshake(let ready):
            // A new connection has no streams, and dsh re-sends everything still
            // waiting on a person to each new `$events` client. Cards held from
            // before may have been answered — or died with a restarted dsh —
            // while this phone was away; the re-send puts back the ones that
            // are real.
            approvals = [:]
            questions = [:]
            harnessInfo = ready.harness
            harnessKnown = true
            harnessDetail = ready.dshReachable ? nil : (ready.detail ?? "dsh isn’t running on that Mac.")
            if let described = MachineDescription(ready: ready) {
                machineInfo = described
            }
            if let direct = ready.direct { learnedDirect?(direct) }
            attached = false
            if ready.dshReachable { attach() }
        case .note(let entry):
            notes.append(entry)
            if notes.count > connectionLogLimit {
                notes.removeFirst(notes.count - connectionLogLimit)
            }
        }
    }

    // MARK: - Streams

    /// Open everything this app follows on the machine, on a connection that
    /// has none: the three machine-wide streams, the session list, and a follow
    /// for each conversation held in memory.
    ///
    /// Every stream starts with the whole state — a `ready` and the waiting
    /// requests, a workspace baseline, a projection baseline, a snapshot — so
    /// there is nothing to replay and nothing to reconcile: what arrives
    /// replaces what was held. The session list is read once `$events` is
    /// ready (`syncList`); should `$events` itself fail, it is read anyway.
    private func attach() {
        attached = true
        for task in machineStreams { task.cancel() }
        machineStreams = [
            Task {
                await self.consume({ await $0.events() }, self.handleEvent)
                if self.listSync == nil, !self.everListed { await self.refreshSessions() }
            },
            Task { await self.consume({ await $0.followWorkspaces() }, self.handleWorkspaces) },
            Task { await self.consume({ await $0.followControl() }, self.handleControl) },
        ]
        Task { await self.refreshAccessDefault() }
        for conversation in conversations.values {
            follow(conversation)
            if !conversation.commandsKnown || !conversation.skillsKnown {
                Task { await self.loadCommands(conversation) }
            }
        }
    }

    /// Read one machine-wide stream until it ends.
    ///
    /// A stream cut for a reason that clears by itself (`reopenable`) is
    /// opened again after a pause that doubles while it keeps failing. A lost
    /// connection is not: the next handshake, or dsh coming back, opens
    /// everything at once.
    private func consume(_ open: @escaping (Harness) async -> TunnelStream, _ handle: @escaping (JSONValue) -> Void) async {
        var pause = MachineSession.firstPause
        while !Task.isCancelled {
            let stream = await open(harness)
            do {
                for try await item in stream.items {
                    pause = MachineSession.firstPause
                    handle(item)
                }
                return
            } catch let error as CallError where MachineSession.reopenable(error) {
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, MachineSession.longestPause)
            } catch {
                return
            }
        }
    }

    /// The transient failures of docs/protocol.md §8 that arrive with the
    /// tunnel still up, so no handshake will reopen the stream. dsh spells
    /// its own as `gateway/internal` — among them a follow that skipped a
    /// sequence number, which its own client also answers by reopening.
    private static func reopenable(_ error: CallError) -> Bool {
        ["busy", "slow-consumer", "timeout", "internal", "gateway/internal"].contains(error.code)
    }

    /// The pause before reopening a stream that failed, and its ceiling.
    static var firstPause = Duration.seconds(1)
    private static let longestPause = Duration.seconds(30)

    /// One item from `$events`: approvals and questions, and the session list's
    /// changes (docs/dsh-0.2-protocol.md §5, §6.3).
    private func handleEvent(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "ready":
            // A new `$events` client: dsh re-sends it every request still
            // waiting, so cards from the one before are dropped rather than
            // left standing for requests that may have ended meanwhile.
            eventsClientId = item["clientId"]?.stringValue
            approvals = [:]
            questions = [:]
            listGeneration += 1
            listSync = (generation: listGeneration, dirty: false)
            let generation = listGeneration
            Task { await self.syncList(generation) }
        case "waterfall":
            handleRequest(item)
        case "cancel":
            // Answered somewhere else, or the turn that asked was cancelled.
            guard let eventId = item["eventId"]?.stringValue else { return }
            approvals = approvals.filter { $0.value.id != eventId }
            questions = questions.filter { $0.value.id != eventId }
        case "emit":
            handleEmit(item["event"]?.stringValue ?? "", item["args"]?.arrayValue ?? [])
        default:
            break
        }
    }

    private func handleRequest(_ item: JSONValue) {
        guard let clientId = eventsClientId,
              let eventId = item["eventId"]?.stringValue,
              let agentId = item["agentId"]?.stringValue else { return }
        // A subagent asks in its own name; the card goes where a person is
        // looking — the conversation that spawned it. The answer names the
        // request, not the session, so it reaches the child all the same.
        let sessionId = owner(of: agentId)
        let request = item["request"] ?? .emptyObject
        switch item["event"]?.stringValue {
        case "approval/request":
            let approval = ApprovalRequest(
                id: eventId,
                clientId: clientId,
                sessionId: sessionId,
                approvalId: request["callId"]?.stringValue ?? "",
                toolName: request["toolName"]?.stringValue ?? "a tool",
                reason: request.path("displayReason", "en")?.stringValue ?? request["reason"]?.stringValue,
                at: Date()
            )
            approvals[sessionId] = approval
            notifier.approval(approval, machine: machine.name, title: title(of: sessionId))
        case "user-questions/request":
            let items = (request["questions"]?.arrayValue ?? []).compactMap(QuestionItem.init(json:))
            guard !items.isEmpty else { return }
            let question = QuestionRequest(id: eventId, clientId: clientId, sessionId: sessionId, items: items, at: Date())
            questions[sessionId] = question
            notifier.question(question, machine: machine.name, title: title(of: sessionId))
        default:
            break
        }
    }

    private func handleEmit(_ event: String, _ args: [JSONValue]) {
        let sessionId = args.first?.stringValue ?? ""
        // While the list is being read, its changes are not applied: the read
        // may have started before them, and would then put back what they took
        // away. That they happened is enough — the list is read once more.
        let holding = listSync != nil && event.hasPrefix("api-session/") && event != "api-session/error"
        if holding { listSync?.dirty = true }
        switch event {
        case "api-session/added" where !holding:
            // Upsert: dsh sends this when a session appears and again when its
            // agent comes or goes, often twice in a row.
            guard let summary = args.first.flatMap(SessionSummary.init) else { return }
            guard !summary.isSubagent else { return learnParent(of: summary) }
            if let index = sessions.firstIndex(where: { $0.id == summary.id }) {
                sessions[index] = summary
            } else {
                sessions.insert(summary, at: 0)
            }
        case "api-session/removed":
            if !holding { sessions.removeAll { $0.id == sessionId } }
            drop(sessionId)
            approvals[sessionId] = nil
            questions[sessionId] = nil
        case "api-session/added":
            break
        case "api-session/status":
            let running = args.dropFirst().first?.boolValue ?? false
            if !holding { update(sessionId) {
                $0.running = running
                if running { $0.blank = false }
            } }
            existing(sessionId)?.setRunning(running)
            if !running { notifier.finished(machine: machine.name, title: title(of: sessionId)) }
        case "api-session/activity" where !holding:
            // A message moved the session up the list.
            update(sessionId) {
                $0.updatedAt = Conversation.date(args.dropFirst().first)
                $0.blank = false
            }
            guard let index = sessions.firstIndex(where: { $0.id == sessionId }), index > 0 else { return }
            sessions.insert(sessions.remove(at: index), at: 0)
        case "api-session/error":
            let message = args.dropFirst().first?.stringValue ?? "The agent failed."
            existing(sessionId)?.note(message, kind: .failure)
            if conversations[sessionId] == nil { problem = message }
        default:
            // Settings, credentials, plugins, and whatever a newer dsh adds.
            break
        }
    }

    /// One item from `workspace/follow`: a baseline on every open, then changes.
    private func handleWorkspaces(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "baseline":
            workspaces = (item.path("value", "items")?.arrayValue ?? []).compactMap(Workspace.init)
            archivedSessionIds = MachineSession.ids(item.path("value", "archivedSessionIds"))
            canGroup = true
        case "upsert":
            if let workspace = item["workspace"].flatMap(Workspace.init) { adopt(workspace) }
        case "remove":
            let removed = item["workspaceId"]?.stringValue
            workspaces.removeAll { $0.id == removed }
        case "archived":
            // The whole set each time. `sessions` keeps archived rows and the
            // list filters by this, so both directions apply without a refetch.
            archivedSessionIds = MachineSession.ids(item["archivedSessionIds"])
        default:
            // `order` and `pinned`: this app sorts by activity, not by hand.
            break
        }
    }

    /// One item from `session/control`: projections of every session dsh has
    /// loaded — a baseline per open, then each key that changes.
    private func handleControl(_ item: JSONValue) {
        switch item["type"]?.stringValue {
        case "baseline":
            for (sessionId, block) in item.path("value", "projections")?.objectValue ?? [:] {
                existing(sessionId)?.absorbProjections(block)
                if let title = block.path("values", "title")?.stringValue {
                    update(sessionId) { $0.title = title }
                }
            }
        case "projection":
            guard let sessionId = item["sessionId"]?.stringValue, let key = item["key"]?.stringValue else { return }
            let value = item["value"] ?? .null
            existing(sessionId)?.applyProjection(key: key, value: value, seq: item["seq"]?.intValue ?? 0)
            if key == "title", let title = value.stringValue {
                update(sessionId) { $0.title = title }
            }
        default:
            break
        }
    }

    private static func ids(_ value: JSONValue?) -> Set<String> {
        Set((value?.arrayValue ?? []).compactMap(\.stringValue))
    }

    /// Follow one conversation for as long as it is held and the connection
    /// lasts. Replaces a follow already running for it.
    private func follow(_ conversation: Conversation) {
        let sessionId = conversation.sessionId
        follows[sessionId]?.cancel()
        follows[sessionId] = Task { await self.run(follow: conversation) }
    }

    private func run(follow conversation: Conversation) async {
        var maxMessages = followMessages
        var pause = MachineSession.firstPause
        while !Task.isCancelled, conversations[conversation.sessionId] === conversation {
            let stream = await harness.follow(sessionId: conversation.sessionId, parent: parents[conversation.sessionId], maxMessages: maxMessages)
            do {
                for try await item in stream.items {
                    pause = MachineSession.firstPause
                    receive(follow: item, into: conversation)
                }
                return
            } catch let error as CallError where error.code == "too-large" && maxMessages > 1 {
                // A snapshot over the frame ceiling: a handful of enormous
                // tool results. Fewer messages, until it fits.
                maxMessages /= 2
            } catch let error as CallError where MachineSession.reopenable(error) {
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, MachineSession.longestPause)
            } catch let error as CallError where error.isConnectionLoss || error.code == "upstream-lost" {
                // Opened again with everything else when the connection is back.
                return
            } catch {
                conversation.loading = false
                conversation.note((error as? LocalizedError)?.errorDescription ?? "Could not load this conversation.", kind: .failure)
                return
            }
        }
    }

    private func receive(follow item: JSONValue, into conversation: Conversation) {
        switch item["type"]?.stringValue {
        case "snapshot":
            flushHeld()
            conversation.adopt(snapshot: item)
            conversation.loading = false
        case "event":
            guard let event = item["event"] else { return }
            // After the chunks before it: the message that ends a step must
            // not overtake the text that built it.
            flushHeld()
            conversation.apply(event: event)
            touch(conversation.sessionId, event: event)
        case "assistant-stream":
            guard let frame = item["frame"] else { return }
            if frame["type"]?.stringValue == "chunk" {
                hold(frame, for: conversation)
            } else {
                flushHeld()
                conversation.receiveStream(frame)
            }
        default:
            break
        }
    }

    // MARK: - Streaming

    /// Streamed chunks waiting for the next flush, in arrival order.
    private var held: [(frame: JSONValue, conversation: Conversation)] = []
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
    /// order-preserving and additive, so a batch folded at once is the same
    /// transcript as the chunks folded one by one.
    private func hold(_ frame: JSONValue, for conversation: Conversation) {
        held.append((frame: frame, conversation: conversation))
        guard flushing == nil else { return }
        flushing = Task { [weak self] in
            try? await Task.sleep(for: MachineSession.flushInterval)
            guard !Task.isCancelled else { return }
            self?.flushHeld()
        }
    }

    /// Fold everything held, now. Also called before anything that is not a
    /// chunk, so a stream can never be applied out of order.
    private func flushHeld() {
        flushing?.cancel()
        flushing = nil
        guard !held.isEmpty else { return }
        let batch = held
        held = []
        for entry in batch { entry.conversation.receiveStream(entry.frame) }
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

    // MARK: - Reads

    /// The conversation for a session, creating and following it on first ask.
    ///
    /// Also the record of which one is on screen: the conversation view asks
    /// for its conversation every time it appears, so the most recent ask is
    /// the one being looked at.
    public func conversation(_ sessionId: String) -> Conversation {
        recent.removeAll { $0 == sessionId }
        recent.insert(sessionId, at: 0)
        if let held = conversations[sessionId] { return held }
        let summary = sessions.first { $0.id == sessionId }
        let fresh = Conversation(sessionId: sessionId, title: summary?.title, cwd: summary?.cwd)
        // Set here rather than when the follow opens, which happens from a
        // Task: until it gets a turn the view would hold a conversation with
        // no items and no reason given, which is the empty state.
        fresh.loading = true
        if summary?.running == true { fresh.setRunning(true) }
        fresh.offer(presets: presetOptions)
        conversations[sessionId] = fresh
        for dropped in recent.dropFirst(MachineSession.heldConversations) {
            drop(dropped)
        }
        recent = Array(recent.prefix(MachineSession.heldConversations))
        if attached {
            follow(fresh)
            Task { await loadCommands(fresh) }
        }
        // Independently of the history: the machine knows which model this
        // session is on before it has ever run one, and a wrong model is worth
        // seeing before spending a turn on it rather than after.
        Task { await loadModel(fresh) }
        // Once on open, so the menu can say whether there is anything to look
        // at without making someone tap to find out there is not.
        Task { await loadSubagents(fresh) }
        return fresh
    }

    /// Let go of a conversation: its follow stops, and opening it again starts
    /// from a fresh snapshot.
    private func drop(_ sessionId: String) {
        follows.removeValue(forKey: sessionId)?.cancel()
        conversations[sessionId] = nil
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
        for child in found.children {
            parents[child.id] = SubagentParent(id: conversation.sessionId, mode: child.mode.rawValue)
        }
    }

    /// What the composer offers after a slash: the session's skills, and the
    /// commands the machine will run for it.
    ///
    /// Two calls, and each is allowed to fail on its own: losing the commands
    /// costs a menu entry, not a session. Both are fetched once per open —
    /// neither list changes mid-sentence, and a request per keystroke would —
    /// and again after a reconnect if the first try did not land.
    private func loadCommands(_ conversation: Conversation) async {
        async let skills = try? harness.skills(sessionId: conversation.sessionId)
        async let commands = try? harness.commands(sessionId: conversation.sessionId)
        if let found = await skills {
            conversation.skills = found
            conversation.skillsKnown = true
        }
        if let found = await commands {
            conversation.machineCommands = found
            conversation.commandsKnown = true
        }
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
    ///
    /// Once per connection; `$events` keeps it current from there. The
    /// workspaces come down their own stream.
    public func refreshSessions() async {
        guard listSync == nil, let items = await readList() else { return }
        sessions = listed(items)
    }

    /// Read the list for one `$events` client, the way docs/dsh-0.2-migration.md
    /// D4 lays out: `$events` replays nothing and shares no cut with the list,
    /// so its list changes are held back (`handleEmit`) while the list is read.
    /// If any arrived, the read may predate them, and it is made once more;
    /// whatever the second read says stands, and the next change converges it.
    private func syncList(_ generation: Int) async {
        for attempt in 0..<2 {
            listSync?.dirty = false
            let items = await readList()
            // A newer `$events` client has started its own read.
            guard listGeneration == generation else { return }
            guard let items else {
                listSync = nil
                return
            }
            if listSync?.dirty == true, attempt == 0 { continue }
            sessions = listed(items)
            listSync = nil
            return
        }
    }

    private func readList() async -> [SessionSummary]? {
        reads += 1
        listing = true
        defer {
            reads -= 1
            listing = reads > 0
            everListed = true
        }
        do {
            return try await harness.listSessions()
        } catch let error as CallError where error.isConnectionLoss || error.code == "upstream-lost" {
            // The reconnect will read it again. Saying so would be noise.
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not read the conversation list."
        }
        return nil
    }

    /// The rows the list shows — subagents left out, their parents noted.
    private func listed(_ items: [SessionSummary]) -> [SessionSummary] {
        for item in items where item.isSubagent { learnParent(of: item) }
        return items.filter { !$0.isSubagent }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Note a subagent's parent from its list row, keeping a mode the parent's
    /// catalog already gave.
    private func learnParent(of row: SessionSummary) {
        guard let parent = row.parentSessionId, parents[row.id] == nil else { return }
        parents[row.id] = SubagentParent(id: parent, mode: "unknown")
    }

    /// The conversation in the list a session belongs to: itself, or for a
    /// subagent, the top of its line of parents.
    private func owner(of sessionId: String) -> String {
        var id = sessionId
        var seen: Set<String> = [id]
        while let parent = parents[id]?.id, seen.insert(parent).inserted { id = parent }
        return id
    }

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

    /// Ask which model this session is on.
    ///
    /// Failure is silent. The header falls back to offering the picker, which is
    /// the same thing this call would have enabled.
    private func loadModel(_ conversation: Conversation) async {
        guard let catalog = try? await harness.models(sessionId: conversation.sessionId) else { return }
        conversation.setModel(catalog.current?.name)
    }

    /// Load the page before what is held.
    public func loadOlder(_ conversation: Conversation) async {
        guard conversation.hasMore, let before = conversation.oldestSeq, let through = conversation.cursor,
              !conversation.loading else { return }
        let generation = conversation.generation
        conversation.loading = true
        defer { if conversation.generation == generation { conversation.loading = false } }
        var maxMessages = followMessages
        while true {
            do {
                let page = try await harness.page(
                    sessionId: conversation.sessionId,
                    parent: parents[conversation.sessionId],
                    throughSeq: through,
                    beforeSeq: before,
                    maxMessages: maxMessages
                )
                // A snapshot that landed meanwhile replaced the window this
                // page was meant to extend.
                guard conversation.generation == generation else { return }
                conversation.absorb(page: page)
                return
            } catch let error as CallError where error.code == "too-large" && maxMessages > 1 {
                // As for the snapshot: fewer messages, until the page fits.
                maxMessages /= 2
            } catch let error as CallError where error.isConnectionLoss || error.code == "upstream-lost" {
                // Scrolling back is optional; the person can pull again once
                // the connection is back.
                return
            } catch {
                guard conversation.generation == generation else { return }
                conversation.note((error as? LocalizedError)?.errorDescription ?? "Could not load earlier messages.", kind: .failure)
                return
            }
        }
    }

    // MARK: - Writes

    /// Send a message, showing it immediately.
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
        // A command is not a message. `/permission read-only` typed here has to
        // reach `commands/execute`; sent as a prompt it would land in the log as
        // ordinary words and start a turn with the model guessing what they
        // meant. Only names the machine listed take this path, so a message that
        // merely starts with a slash still goes where it always did.
        //
        // `steer` is deliberately not consulted: it is about the turn already
        // running, and a command does not touch that turn — dsh runs it directly,
        // which is the whole reason `/permission` works mid-answer. Honouring the
        // flag here would turn the command back into words.
        if images.isEmpty, let line = conversation.machineLine(for: text) {
            await runCommand(line, sessionId: sessionId, conversation: conversation)
            return
        }
        // Where the optimistic copy goes depends on where the message is
        // actually going. A steer, or a send to an idle session, is claimed
        // immediately — the transcript is the truth about it. A queued send to
        // a *running* session is not said to the model at all yet, and showing
        // it as a bubble puts two contradictory claims on one screen: the
        // transcript reading "delivered" while the queue strip below offers to
        // promote or withdraw the very same words. It waits where it actually
        // is — at the bottom, in the strip — and enters the transcript when
        // the machine's own `user/message` says it was heard.
        //
        // Either copy is shown under the request id the message is sent with,
        // which the machine logs on it — that is how the copy is retired.
        let requestId = UUID().uuidString
        if !steer && conversation.running {
            conversation.showQueued(text: text, id: requestId)
            do {
                try await harness.prompt(sessionId: sessionId, requestId: requestId, text: text, images: images, steer: false)
            } catch {
                await settleFailedSend(error, in: conversation, isStill: { conversation.isQueued(id: requestId) }) {
                    conversation.dropQueued(id: requestId)
                }
            }
            return
        }
        conversation.showPending(text: text, id: requestId)
        do {
            try await harness.prompt(sessionId: sessionId, requestId: requestId, text: text, images: images, steer: steer)
        } catch {
            await settleFailedSend(error, in: conversation, isStill: { conversation.isPending(id: requestId) }) {
                conversation.dropPending(id: requestId)
            }
        }
    }

    /// How long a message whose send was cut off waits for the machine to show
    /// it arrived, before this device says it did not. Long enough to cover a
    /// reconnect and the snapshot after it; tests shorten it.
    var unconfirmedSendWait: Duration = .seconds(30)

    /// Deal with a send that did not come back cleanly.
    ///
    /// "Didn't send" is only true when nothing left this device. A send cut off
    /// after it was written may have reached the machine, and telling someone
    /// it did not is how the same instruction gets given twice. So that copy
    /// stays up: when the machine's own `user/message` arrives — in the
    /// reconnect's snapshot, usually within seconds — it replaces it as usual.
    /// Only if nothing comes in `unconfirmedSendWait` is it taken back.
    private func settleFailedSend(
        _ error: Error,
        in conversation: Conversation,
        isStill: () -> Bool,
        drop: () -> Void
    ) async {
        guard (error as? CallError)?.outcomeUnknown == true else {
            drop()
            problem = (error as? LocalizedError)?.errorDescription ?? "That message didn’t send."
            return
        }
        try? await Task.sleep(for: unconfirmedSendWait)
        // A conversation dropped meanwhile is rebuilt from the machine's log
        // when it is opened again, which shows whether the message arrived.
        guard isStill(), conversations[conversation.sessionId] === conversation else { return }
        drop()
        problem = "That message may not have reached the Mac — the connection dropped before it answered. Check before sending it again."
    }

    /// Run a slash command against one session.
    ///
    /// No bubble goes up for this, and that is not an omission: the machine logs
    /// the command itself (`command/run`, then `command/done`) and the
    /// transcript draws the outcome from those events, so an optimistic copy
    /// here would be a second, worse account of the same act.
    ///
    /// A refusal is shown where the words were typed rather than in the banner
    /// over the app: the machine's own text names the reason — an unknown preset
    /// lists the ones it has — and this is a reply to one message, not a fault of
    /// the session.
    private func runCommand(_ line: String, sessionId: String, conversation: Conversation) async {
        do {
            let ran = try await harness.command(sessionId: sessionId, line: line)
            guard ran != nil else {
                // The machine was asked for its commands and listed this one, so
                // a name it does not know now means something changed underneath
                // — a plugin unmounted. Said plainly, and the words are not sent
                // to the model as a consolation: they are a command, and a model
                // reading "/permission read-only" is exactly the wrong outcome.
                let name = line.dropFirst().prefix { !$0.isWhitespace }
                conversation.note("This Mac no longer has a /\(name) command.", kind: .failure)
                return
            }
        } catch {
            let said = (error as? LocalizedError)?.errorDescription ?? "That command didn’t run."
            conversation.note(said, kind: .failure)
        }
    }

    /// Cut a queued message into the running turn. dsh moves it from the
    /// next turn's queue to the running one's; the `inbox` projection shows it.
    public func promote(sessionId: String, item: QueuedMessage) async {
        do {
            try await harness.updateQueue(sessionId: sessionId, itemId: item.id, action: .steer)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That message could not be moved up."
        }
    }

    public func cancel(sessionId: String) async {
        do { try await harness.cancel(sessionId: sessionId) } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not stop the agent."
        }
    }

    /// What new conversations on this machine start as. Nil until read.
    public private(set) var accessDefault: PermissionChoice?
    /// The presets a conversation can be switched to. See `Conversation.offer`.
    @ObservationIgnored private var presetOptions: [PermissionChoice.Option] = []

    /// Read the machine's access presets: its default, and the choices every
    /// held conversation offers.
    public func refreshAccessDefault() async {
        guard let catalog = try? await harness.permissionPresets() else { return }
        accessDefault = catalog.defaults ?? accessDefault
        presetOptions = catalog.options
        for conversation in conversations.values { conversation.offer(presets: catalog.options) }
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
            accessDefault = PermissionChoice(current: preset, options: accessDefault?.options ?? [])
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
        let workspace = await workspace(for: cwd)
        do {
            // A workspace or a folder, never both: dsh refuses the pair, and a
            // conversation started in a workspace runs in its folder anyway.
            let id = try await harness.createSession(
                cwd: workspace == nil ? cwd : nil,
                workspaceId: workspace?.id,
                agentPreset: preset
            )
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
            summary?.cwd = workspace?.path ?? cwd
            if let summary, !sessions.contains(where: { $0.id == id }) {
                sessions.insert(summary, at: 0)
            }
            return id
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Could not start a conversation."
            return nil
        }
    }

    /// The workspace a conversation started in this folder belongs in, made
    /// on the spot when the folder has none.
    ///
    /// Started with `workspaceId`, a conversation is filed in the machine's
    /// ledger as it is made. Filing it afterwards does not work on dsh 0.2: the
    /// ledger compares the session's folder with the workspace's as strings,
    /// and the workspace's has been resolved (`/private/var/…` for `/var/…`),
    /// so the two disagree and the filing is refused.
    ///
    /// A folder nothing stands for is claimed on the way. The ledger is only
    /// written when a conversation is started in a workspace and nothing on the
    /// wire backfills it, so a conversation started before its folder had one
    /// is missing from the Mac's sidebar for good. Claiming here spends nothing
    /// the person has not already decided — they chose this folder — and costs
    /// a removable row on the Mac with nothing on disk behind it.
    ///
    /// - Returns: nil when there is nothing to join or make — the machine has
    ///   not described its workspaces, the folder is the Mac's own default, or
    ///   the claim was refused — and the conversation starts in the folder.
    private func workspace(for folder: String?) async -> Workspace? {
        switch placement(for: folder) {
        case .joins(let workspaceId, _):
            return workspaces.first { $0.id == workspaceId }
        case .ungrouped:
            guard let folder, let made = try? await harness.createWorkspace(path: folder) else { return nil }
            adopt(made.workspace)
            return made.workspace
        case .unknown:
            return nil
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
    /// Marked rather than removed. `session/list` keeps answering with archived
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
            existing(sessionId)?.retitle(title)
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
            // Back only if it is still this client's to answer and nothing
            // newer has taken its place.
            if approval.clientId == eventsClientId, approvals[approval.sessionId] == nil {
                approvals[approval.sessionId] = approval
            }
            problem = (error as? LocalizedError)?.errorDescription ?? "That answer didn’t reach the Mac."
        }
    }

    public func answer(question: QuestionRequest, answers: [String: QuestionAnswer]) async {
        questions[question.sessionId] = nil
        do {
            try await harness.answerQuestion(question, answers: answers)
        } catch {
            if question.clientId == eventsClientId, questions[question.sessionId] == nil {
                questions[question.sessionId] = question
            }
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

    /// Feed one `$events` item, as its stream does. The `ready` that names
    /// this client comes first, as it does from dsh.
    func receiveForTesting(events item: JSONValue) {
        if eventsClientId == nil { handleEvent(.object(["type": .string("ready"), "clientId": .string("test-client")])) }
        handleEvent(item)
    }

    /// Feed one `workspace/follow` item, as its stream does.
    func receiveForTesting(workspaces item: JSONValue) {
        handleWorkspaces(item)
    }

    /// Feed one `session/follow` item to a held conversation, as its stream does.
    func receiveForTesting(follow item: JSONValue, sessionId: String) {
        guard let conversation = conversations[sessionId] else { return }
        receive(follow: item, into: conversation)
    }
}
