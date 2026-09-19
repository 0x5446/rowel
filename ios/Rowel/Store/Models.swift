/// What the screens render.
///
/// These are the app's own types, not the harness's. The harness vocabulary is
/// open — plugins add event types and tool cards — so the boundary is deliberate:
/// `Conversation` folds whatever arrives into this closed set, and anything it
/// does not recognise becomes a plain notice rather than nothing at all.

import Foundation

/// A machine this device has paired with.
public struct PairedMachine: Codable, Identifiable, Equatable, Sendable {
    /// The Relay device id. Stable for the life of the machine's install.
    public var id: String
    /// Display name, from the machine, editable here.
    public var name: String
    /// Relay base URL.
    public var relay: String
    /// LAN addresses last advertised, best first.
    public var direct: [String]
    /// The machine's raw static public key, base64url.
    public var key: String
    public var addedAt: Date
    /// How the last successful connection got there, for the status line.
    public var lastCarrier: Carrier?
    /// What the Mac itself calls this machine, as of the last pairing.
    ///
    /// Kept apart from `name` so a rename on this phone survives re-pairing:
    /// `name` belongs to the person holding the phone, this belongs to the
    /// Mac, and "Use the Mac's name" is an explicit act that copies one over
    /// the other. Optional because pairings made before this field existed
    /// decoded without it.
    public var reportedName: String?

    public init(bundle: PairingBundle, addedAt: Date = Date()) {
        id = bundle.device
        name = bundle.name
        relay = bundle.relay
        direct = bundle.direct ?? []
        key = bundle.key
        self.addedAt = addedAt
        reportedName = bundle.name.isEmpty ? nil : bundle.name
    }

    /// A bundle for reconnecting. No token: the pairing already happened, and
    /// this device is recognised by its key from here on.
    ///
    /// The relay address is resolved through `currentRelayURL` rather than used
    /// as stored. A pairing carries the address it was made at, and one of
    /// those addresses has since been retired — without this, every machine
    /// paired before the move would go on dialling a host that no longer
    /// answers, and the only symptom would be a connection that never
    /// completes.
    public var reconnectBundle: PairingBundle {
        PairingBundle(
            relay: currentRelayURL(for: relay),
            direct: direct,
            device: id,
            key: key,
            token: "",
            name: name
        )
    }

    /// Absorb a fresh pairing bundle into this record.
    ///
    /// Re-pairing is how someone recovers from a moved Mac, so the wire facts
    /// — addresses, key, relay — are the bundle's to overwrite. The two things
    /// that are not: when this pairing was made, and what the person holding
    /// the phone calls it. The name used to travel with the wire facts, and a
    /// re-pair silently undid the rename someone made precisely to tell two
    /// same-named machines apart. What the Mac calls itself still arrives,
    /// into `reportedName`, where "Use the Mac's name" can reach it.
    /// Pure, and tested directly — the pairing flow just applies it.
    public func absorbing(_ bundle: PairingBundle) -> PairedMachine {
        var merged = PairedMachine(bundle: bundle)
        merged.addedAt = addedAt
        merged.name = name
        merged.reportedName = bundle.name.isEmpty ? reportedName : bundle.name
        return merged
    }

    /// Human-readable identity check, matching what `bridle devices` prints.
    public var fingerprint: String {
        guard let raw = Data(base64url: key) else { return "unknown" }
        return Pairing.keyFingerprint(raw)
    }
}

/// What to call each paired machine on screen.
///
/// Machine names default to the Mac's hostname, so two Bridle identities on
/// one Mac — a real one and a demo one is the observed case — arrive with the
/// same name, and every surface that shows it (the chip, the list, the
/// offline banner) says the same thing about two different machines. The
/// suffix that tells them apart is **derived at render time and only under
/// collision**: someone with one Mac never sees it, and the moment a
/// colliding pairing is forgotten or renamed it disappears on its own —
/// which a suffix written into the stored name at pair time would not.
///
/// The suffix must be rendered as its own element, never concatenated into
/// the name: names truncate from the end, and the end is exactly where a
/// concatenated suffix would be cut off. See `MachineChip`.
public struct MachineLabel: Equatable, Sendable {
    public let name: String
    /// Present only when another pairing shares the display name.
    public let suffix: String?

    /// The one-line form for prose ("Can't reach X"), where truncation is not
    /// the enemy and a separate view is not available.
    public var prose: String {
        suffix == nil ? name : "\(name) · \(suffix ?? "")"
    }

    /// - Parameters:
    ///   - machine: the machine to label.
    ///   - among: every paired machine, for collision detection.
    public static func resolve(_ machine: PairedMachine, among machines: [PairedMachine]) -> MachineLabel {
        let rivals = machines.filter { $0.name == machine.name && $0.id != machine.id }
        guard !rivals.isEmpty else { return MachineLabel(name: machine.name, suffix: nil) }
        return MachineLabel(
            name: machine.name,
            suffix: disambiguate(compact(machine.fingerprint), against: rivals.map { compact($0.fingerprint) })
        )
    }

    /// Fingerprint prefix, grown until it separates this one from every rival.
    ///
    /// Four hex characters collide about once in sixty-five thousand, but
    /// "about never" is not a rule, so the rule is growth. Separated from
    /// `resolve` so the growth can be tested with crafted fingerprints
    /// rather than by mining keys for a real collision.
    static func disambiguate(_ mine: String, against others: [String]) -> String {
        for length in stride(from: 4, through: mine.count, by: 4) {
            let candidate = String(mine.prefix(length))
            if !others.contains(where: { $0.hasPrefix(candidate) }) {
                return candidate
            }
        }
        return mine
    }

    private static func compact(_ fingerprint: String) -> String {
        fingerprint.replacingOccurrences(of: "-", with: "")
    }
}

/// One row in the session list.
public struct SessionSummary: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String?
    public var updatedAt: Date
    public var running: Bool
    /// True until the first prompt: an untouched session nobody has used yet.
    public var blank: Bool
    public var cwd: String?
    public var agentPreset: String?
    public var parentSessionId: String?
    /// Set when this session is a subagent's, which the list hides by default.
    public var isSubagent: Bool

    /// What to show when the session has no title yet.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if blank { return "New conversation" }
        if let cwd { return (cwd as NSString).lastPathComponent }
        return "Untitled"
    }

    /// Parse one `session.list` row.
    public init?(_ value: JSONValue) {
        guard let id = value["sessionId"]?.stringValue else { return nil }
        self.id = id
        updatedAt = Date(timeIntervalSince1970: (value["updatedAt"]?.doubleValue ?? 0) / 1000)
        running = value["running"]?.boolValue ?? false
        blank = value["blank"]?.boolValue ?? false
        cwd = value["cwd"]?.stringValue
        agentPreset = value["agentPreset"]?.stringValue
        parentSessionId = value["parentSessionId"]?.stringValue
        isSubagent = value["origin"]?.stringValue == "subagent"
        title = value.path("projections", "values", "title")?.stringValue
    }
}

// MARK: - Workspaces

/// One of the machine's sidebar groups.
///
/// dsh's own filing system, arranged by whoever sits at the keyboard. A
/// workspace *is* a directory: the machine canonicalises the path it was made
/// from and a conversation belongs to the workspace whose path is exactly its
/// own working directory. Nothing else joins the two — there is no dragging a
/// conversation into a folder it does not run in.
///
/// Membership is a list of session ids held by the workspace rather than a
/// field on the session — and the list is a ledger, not the truth. The machine
/// writes it only when a conversation is created *into* the workspace, so
/// everything started before the workspace existed, or from a terminal on the
/// Mac, is missing from it forever; no call it exposes backfills the past.
/// `SessionBoard` therefore treats the ledger as one source and the rule the
/// ledger caches — path equals working directory — as the other.
public struct Workspace: Identifiable, Equatable, Sendable {
    public var id: String
    /// The folder the workspace stands for, when it stands for one.
    public var path: String?
    /// The name someone gave it. The machine defaults it to the folder's own
    /// name at creation, so in practice this is nearly always present — but a
    /// row without one is still a row.
    public var title: String?
    /// Members, in the order the machine keeps them.
    public var sessionIds: [String]
    public var createdAt: Date

    /// What to call it in a header.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return "Workspace"
    }

    /// Parse one `workspace.list` row.
    public init?(_ value: JSONValue) {
        guard let id = value["workspaceId"]?.stringValue else { return nil }
        self.id = id
        path = value["path"]?.stringValue
        title = value["title"]?.stringValue
        sessionIds = (value["sessionIds"]?.arrayValue ?? []).compactMap { $0.stringValue }
        createdAt = Workspace.instant(value["createdAt"]) ?? Date(timeIntervalSince1970: 0)
    }

    /// Workspaces stamp their times as ISO-8601 strings, unlike sessions, whose
    /// `updatedAt` is epoch milliseconds. Reading this as a number — which is
    /// what the first version did — silently made every workspace date 1970.
    /// Both spellings are accepted rather than the one seen today, because
    /// guessing wrong once already cost a field.
    static func instant(_ value: JSONValue?) -> Date? {
        if let milliseconds = value?.doubleValue { return Date(timeIntervalSince1970: milliseconds / 1000) }
        guard let text = value?.stringValue else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    public init(id: String, path: String? = nil, title: String? = nil, sessionIds: [String], createdAt: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.createdAt = createdAt
    }
}

/// Where a conversation started in a given folder will end up.
///
/// The question the folder browser could not answer before: someone picks
/// `~/workspace/thing`, taps start, and finds the conversation either under a
/// section they recognise or in the leftovers, with no way to have known which.
///
/// The rule is exact-match, and it has to be. The machine files a conversation
/// under the workspace whose path *equals* its working directory, so a folder
/// inside a workspace is not in that workspace — and this is not a hypothetical:
/// a machine with both `~/code` and `~/code/invoice-service` registered is
/// the shape this was written against, and prefix matching would
/// name the wrong one for every conversation in the nested folder.
public enum WorkspacePlacement: Equatable, Sendable {
    /// A workspace stands for exactly this folder, and a conversation started
    /// here joins it.
    case joins(workspaceId: String, title: String)
    /// No workspace stands for this folder, so the conversation will sit on its
    /// own until someone makes one.
    case ungrouped
    /// The machine has not said whether it groups at all — an older dsh with no
    /// `workspace.list`, or one that has not answered yet. Nothing may be
    /// claimed either way, so the screens say nothing.
    case unknown

    /// - Parameters:
    ///   - path: the folder in question, or nil for "wherever the Mac defaults
    ///     to", which cannot be resolved from here.
    ///   - workspaces: the machine's groups as last read.
    ///   - grouping: whether `workspace.list` has ever succeeded on this
    ///     machine. False means unknown rather than empty — see the enum.
    public static func resolve(path: String?, workspaces: [Workspace], grouping: Bool) -> WorkspacePlacement {
        guard grouping else { return .unknown }
        guard let path, !path.isEmpty else { return .unknown }
        let wanted = WorkspacePlacement.canonical(path)
        guard let match = workspaces.first(where: { $0.path.map(WorkspacePlacement.canonical) == wanted }) else {
            return .ungrouped
        }
        return .joins(workspaceId: match.id, title: match.displayTitle)
    }

    /// The workspace this folder is, if any.
    public var workspaceId: String? {
        if case .joins(let id, _) = self { return id }
        return nil
    }

    /// Both ends already normalise — the machine through `realpath`, the folder
    /// browser through `path.resolve` — so this only has to agree about the
    /// trailing slash, which neither of them produces but a hand-typed or
    /// remembered path can. Anything subtler than that (a symlinked home, two
    /// spellings of the same volume) is left to disagree: guessing that two
    /// unequal paths are the same folder would put a conversation under a name
    /// that turns out to be wrong, and being told "ungrouped" and finding it
    /// grouped is the kinder mistake of the two.
    ///
    /// Shared with `SessionBoard`, whose sweep must agree with this resolution
    /// about what "the same folder" means or the two screens would file one
    /// conversation two ways.
    static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// What can be done about a conversation no workspace section shows.
///
/// There is exactly one thing, and it is worth being blunt about why. A
/// conversation belongs to the workspace whose folder is its own working
/// folder, and a conversation's working folder never changes — so there is no
/// "move to another workspace" to build. `workspace.insertSessionBefore` sounds
/// like the call for it and is not: it reorders inside the one workspace that
/// already accounts a session and refuses anything else.
///
/// A folder that already has a workspace offers nothing either, and that is
/// new: `SessionBoard` seats a conversation under the workspace for its
/// working directory whether or not the machine's ledger lists it, so "move
/// into the group it is already shown in" would be a button that visibly does
/// nothing. What is left is the folder no workspace stands for at all — and
/// claiming it seats every conversation from that folder at once, not just
/// the row that was pressed.
public enum SessionFiling: Equatable, Sendable {
    /// Nothing to offer. Already shown under a workspace, no folder recorded,
    /// or a machine that has not said it groups.
    case settled
    /// Nothing stands for the folder yet. Claiming it makes the workspace, and
    /// the board seats the folder's conversations on its own.
    case claim(path: String)

    public static func resolve(_ summary: SessionSummary, workspaces: [Workspace], grouping: Bool) -> SessionFiling {
        guard grouping, let cwd = summary.cwd, !cwd.isEmpty else { return .settled }
        // Held by *any* workspace, not just the one matching the folder. A
        // conversation the machine already filed is not the app's business,
        // even if the accounting looks odd from here.
        guard !workspaces.contains(where: { $0.sessionIds.contains(summary.id) }) else { return .settled }
        switch WorkspacePlacement.resolve(path: cwd, workspaces: workspaces, grouping: grouping) {
        case .joins: return .settled
        case .ungrouped: return .claim(path: cwd)
        case .unknown: return .settled
        }
    }
}

/// One section of the conversation list.
public struct SessionGroup: Identifiable, Equatable, Sendable {
    /// The id of the catch-all section.
    ///
    /// A sentinel rather than an optional id, because this id is also the key
    /// the fold state is remembered under and an optional would need a second
    /// spelling there. dsh mints workspace ids, so a real one cannot collide
    /// with a dotted name in this app's own namespace.
    public static let ungroupedId = "rowel.ungrouped"

    public var id: String
    public var title: String
    public var sessions: [SessionSummary]
    /// The newest thing in this group, which is what the sections are ordered
    /// by and what decides which one opens on a cold launch.
    public var lastActivity: Date

    public var isUngrouped: Bool { id == SessionGroup.ungroupedId }
}

/// The conversation list, arranged the way the home screen draws it.
///
/// Pure, and deliberately so: this is the part with rules worth stating — what
/// happens to a session no workspace claims, to a workspace that names a
/// session the machine no longer has, to a conversation that is holding
/// everything up — and rules buried in a `body` cannot be tested.
///
/// Two decisions are worth reading twice.
///
/// **Sections are ordered by activity, not by the order on the Mac.** dsh keeps
/// a hand-arranged sidebar order and sends `host/workspace-order-changed` when
/// it moves. That order is a filing decision made at a desk; a phone is opened
/// to carry on with something, so the thing touched most recently belongs at
/// the top. The cost is real: someone who deliberately dragged a workspace to
/// the top of their sidebar will not see that reflected here.
///
/// **Anything waiting on the person is lifted out of its group entirely.** A
/// tool asking for permission inside a folded section is the worst thing this
/// screen could do — the whole reason the app exists is being interrupted away
/// from the keyboard. Lifting rather than copying keeps every conversation on
/// screen exactly once; the price is that answering the prompt drops the row
/// back into its group, and that a group holding nothing but a waiting
/// conversation disappears until it is answered.
public struct SessionBoard: Equatable {
    /// Conversations that cannot go on without an answer. Above every section
    /// and outside every fold.
    public var waiting: [SessionSummary]
    public var groups: [SessionGroup]
    /// Which section to open when nobody has said otherwise, or nil when there
    /// is nothing to fold.
    ///
    /// One, not all: 44 conversations fully expanded is a scroll, and the point
    /// of the sections is to make the shape visible in a screen. The most
    /// recently touched one is the safe guess, because opening the app almost
    /// always means carrying on with what was already happening.
    public var openByDefault: String?

    /// False when there is nothing to divide — no workspaces, one workspace, or
    /// a machine too old to have the call. The screen then draws the plain list
    /// it drew before any of this existed.
    public var grouped: Bool { groups.count > 1 }

    /// - Parameter archived: conversations the machine has filed away. Dropped
    ///   before anything else, including the lift for whatever is waiting: the
    ///   machine's own rule is that an archived conversation "disappears from
    ///   every grouping surface", and an exception for a stuck one would put a
    ///   row on screen that someone deliberately made go away.
    public init(sessions: [SessionSummary], workspaces: [Workspace], waitingOn: Set<String> = [], archived: Set<String> = []) {
        let visible = archived.isEmpty ? sessions : sessions.filter { !archived.contains($0.id) }
        let ordered = visible.sorted(by: SessionBoard.newestFirst)
        waiting = ordered.filter { waitingOn.contains($0.id) }

        let rest = ordered.filter { !waitingOn.contains($0.id) }
        // `uniquingKeysWith` rather than the unique-keys initialiser: a machine
        // that ever answered with the same session twice would take the home
        // screen down with a trap, and a duplicated row is the lesser failure.
        let byId = Dictionary(rest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var claimed: Set<String> = []
        var made: [SessionGroup] = []
        for workspace in workspaces {
            var members: [SessionSummary] = []
            for id in workspace.sessionIds {
                // A workspace can name a session that `session.list` does not
                // return — archived, deleted, or a subagent the list hides — and
                // the only honest thing to do with a name that resolves to
                // nothing is skip it. First claim wins if two workspaces name
                // the same session, so no conversation appears twice.
                guard !claimed.contains(id), let summary = byId[id] else { continue }
                claimed.insert(id)
                members.append(summary)
            }
            // The ledger, then the rule the ledger caches. Membership is
            // written only when a conversation is created into the workspace,
            // so everything started before the workspace existed — or from a
            // terminal on the Mac — is missing from it forever, and no exposed
            // call backfills it; a machine with years of history shows almost
            // everything as leftovers under sections made for exactly those
            // folders. The rule itself is exact and checkable from here: the
            // machine refuses to account a conversation anywhere but the
            // workspace whose path *is* its working directory, so seating by
            // working directory reaches the same grouping the ledger would
            // have reached. It just does not wait to be told.
            if let path = workspace.path, !path.isEmpty {
                let wanted = WorkspacePlacement.canonical(path)
                for summary in rest where !claimed.contains(summary.id) {
                    guard let cwd = summary.cwd, WorkspacePlacement.canonical(cwd) == wanted else { continue }
                    claimed.insert(summary.id)
                    members.append(summary)
                }
            }
            // An empty workspace is a header with nothing under it, which reads
            // as a bug rather than as information.
            guard !members.isEmpty else { continue }
            members.sort(by: SessionBoard.newestFirst)
            made.append(SessionGroup(
                id: workspace.id,
                title: workspace.displayTitle,
                sessions: members,
                lastActivity: members[0].updatedAt
            ))
        }
        // Ties broken by id, so two workspaces last touched in the same second
        // cannot swap places between one render and the next.
        made.sort { ($0.lastActivity, $0.id) > ($1.lastActivity, $1.id) }

        let loose = rest.filter { !claimed.contains($0.id) }
        if !loose.isEmpty {
            // Last, whatever its timestamps say. It is not a place someone put
            // anything; it is what is left over, and leftovers do not outrank
            // the folders somebody made on purpose.
            made.append(SessionGroup(
                id: SessionGroup.ungroupedId,
                title: "Ungrouped",
                sessions: loose,
                lastActivity: loose[0].updatedAt
            ))
        }
        groups = made
        // Chosen across all sections including the leftovers, unlike the
        // ordering: where the newest conversation *sits* should not change
        // whether it is reachable without a tap.
        openByDefault = made.count > 1 ? made.max { $0.lastActivity < $1.lastActivity }?.id : nil
    }

    private static func newestFirst(_ left: SessionSummary, _ right: SessionSummary) -> Bool {
        (left.updatedAt, left.id) > (right.updatedAt, right.id)
    }
}

/// One rendered item in a conversation, in log order.
public enum ConversationItem: Identifiable, Equatable {
    case user(UserTurn)
    case assistant(AssistantTurn)
    case tool(ToolCard)
    case notice(Notice)

    public var id: String {
        switch self {
        case .user(let item): return item.id
        case .assistant(let item): return item.id
        case .tool(let item): return item.id
        case .notice(let item): return item.id
        }
    }
}

/// Something the person said, or a synthetic message injected on their behalf.
public struct UserTurn: Identifiable, Equatable {
    public var id: String
    public var text: String
    /// Attached images, as data URLs the view can render directly.
    public var images: [ImageAttachment]
    /// True for context the harness injected rather than something typed.
    public var synthetic: Bool
    public var at: Date
}

/// An image carried by a message.
public struct ImageAttachment: Equatable, Identifiable {
    public var id: String
    public var mediaType: String
    /// Base64 payload, when it travelled inline.
    public var base64: String?
}

/// One assistant response, possibly still streaming.
public struct AssistantTurn: Identifiable, Equatable {
    public var id: String
    public var turn: Int
    public var step: Int
    public var text: String
    /// Reasoning content, shown collapsed.
    public var reasoning: String
    /// False while chunks are still arriving.
    public var complete: Bool
    public var at: Date
}

/// How a tool call wants to be drawn. Mirrors the harness's render intent, which
/// the machine computes so the app never has to know what a given tool does.
public enum ToolPresentation: Equatable {
    case generic(title: String, kind: String?, detail: String?)
    case terminal(command: String, cwd: String?, output: String?, exitCode: Int?)
    case diff(title: String, files: [FileDiff])
    case search(title: String, lines: [String], truncated: Bool, total: Int)
    case read(path: String, lines: [NumberedLine], totalLines: Int)
}

/// One file's before and after, for the diff card.
public struct FileDiff: Equatable, Identifiable {
    public var id: String { path }
    public var path: String
    public var oldText: String?
    public var newText: String
}

/// One line of a read result, keeping the file's own numbering.
public struct NumberedLine: Equatable, Identifiable {
    public var id: Int { number }
    public var number: Int
    public var text: String
}

/// A tool call and, once it lands, its result.
public struct ToolCard: Identifiable, Equatable {
    public var id: String
    public var name: String
    /// Raw arguments as the model produced them, for the expanded view.
    public var arguments: String
    public var presentation: ToolPresentation
    /// Model-facing result text, shown when there is no better card.
    public var resultText: String?
    public var failed: Bool
    public var running: Bool
    public var at: Date
    /// When `tool/result` arrived. The events carry no duration field, so this
    /// is the only place a *measured* one comes from — everything else in the
    /// log can only be timed by the gap to whatever happened next.
    public var finishedAt: Date?

    /// How long the tool ran, once it has stopped.
    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(at) }
    }

    /// A short line for the collapsed row.
    public var headline: String {
        switch presentation {
        case .generic(let title, _, _): return title
        case .terminal(let command, _, _, _): return command
        case .diff(let title, _): return title
        case .search(let title, _, _, _): return title
        case .read(let path, _, _): return (path as NSString).lastPathComponent
        }
    }
}

/// Anything that is neither a message nor a tool: mode changes, compaction,
/// errors, and event types this build has never heard of.
public struct Notice: Identifiable, Equatable {
    public enum Kind: Equatable {
        case info
        case warning
        case failure
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var at: Date
}

/// A tool waiting for the person to allow or refuse it.
public struct ApprovalRequest: Identifiable, Equatable {
    /// The harness rpcId, echoed back with the answer.
    public var id: String
    public var sessionId: String
    public var approvalId: String
    public var toolName: String
    public var reason: String?
    public var at: Date
}

/// A question the agent asked, with its options.
public struct QuestionRequest: Identifiable, Equatable {
    public var id: String
    public var sessionId: String
    public var items: [QuestionItem]
    public var at: Date
}

/// One question inside a batch.
public struct QuestionItem: Identifiable, Equatable {
    public var id: String
    public var question: String
    public var header: String?
    public var detail: String?
    public var options: [QuestionOption]
    public var multiSelect: Bool
    /// The label that approves, when the agent is submitting a plan for review.
    /// Present only for `plan-review`; every other option declines.
    public var approveLabel: String?

    /// Whether this question is a plan waiting for a verdict, which the app
    /// renders as a document with two buttons rather than as a menu.
    public var isPlanReview: Bool { approveLabel != nil }
}

/// One selectable answer.
public struct QuestionOption: Identifiable, Equatable {
    public var id: String { label }
    public var label: String
    public var description: String?
}

/// One item on the agent's checklist.
public struct TodoItem: Identifiable, Equatable {
    public enum Status: String, Equatable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String { "\(content)#\(status.rawValue)" }
    public var content: String
    public var status: Status
}

/// A message the person sent that the agent has not claimed yet.
public struct QueuedMessage: Identifiable, Equatable {
    public var id: String
    public var text: String
    /// `queued`, `steering`, or `context`.
    public var placement: String
}

/// One entry in the folder browser used when starting a conversation.
public struct DirectoryEntry: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var hidden: Bool
}

/// A folder listing plus the trail back to the root.
public struct DirectoryListing: Equatable {
    public var path: String
    public var home: String
    public var crumbs: [DirectoryEntry]
    public var entries: [DirectoryEntry]
    public var truncated: Bool
}

/// One model the session can switch to.
public struct ModelOption: Identifiable, Equatable, Codable {
    public var id: String { "\(provider)/\(model)" }
    public var provider: String
    public var providerName: String
    public var model: String
    public var name: String
    public var description: String?
}

/// How hard the model is asked to think before answering.
///
/// Per model, not per provider — the same provider ships models with and
/// without it, so the choice has to follow the model the picker is showing.
public struct ReasoningEffort: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
}

/// The models available to a session, and the one in use.
public struct ModelCatalog: Equatable {
    public var current: ModelOption?
    public var options: [ModelOption]
    /// Provider groups that failed to load, so the picker can say why.
    public var failures: [String]
    /// Reasoning levels per model id, and each model's own default.
    ///
    /// Kept beside the options rather than inside `ModelOption`, because that
    /// type is persisted as the "new conversations use" choice and adding a
    /// required field to it would make every stored one fail to decode.
    public var efforts: [String: [ReasoningEffort]] = [:]
    public var defaultEfforts: [String: String] = [:]
    /// What the session is set to right now, when the model supports it.
    public var currentEffort: String?

    /// The levels this model offers. Empty means it does not take one.
    public func efforts(for option: ModelOption) -> [ReasoningEffort] {
        efforts[option.id] ?? []
    }

    /// The level to preselect for a model the session is not already on.
    public func defaultEffort(for option: ModelOption) -> String? {
        defaultEfforts[option.id]
    }
}

/// What the machine says about itself.
public struct MachineDescription: Equatable {
    public var version: String
    public var cwd: String
    public var provider: String?
    public var model: String?
    public var attachedSessions: Int

    public init?(_ value: JSONValue?) {
        guard let value, let version = value["version"]?.stringValue else { return nil }
        self.version = version
        cwd = value["cwd"]?.stringValue ?? "~"
        provider = value["provider"]?.stringValue
        model = value["model"]?.stringValue
        attachedSessions = value["attachedSessions"]?.intValue ?? 0
    }
}

// MARK: - What the session cost

/// Time and shape of the work so far.
///
/// Every field here is already arriving in the `sessionStats` projection, and
/// was being dropped on the floor. On a phone this is the answer to the two
/// questions the transcript cannot answer at a glance — *is it stuck* and *is
/// this getting expensive* — so it costs nothing to keep and reads as the
/// summary line the web UI puts under its composer.
public struct SessionStats: Equatable, Sendable {
    public var turns: Int
    public var steps: Int
    public var llmMs: Int
    public var toolMs: Int
    /// Time to first token, summed over `ttftSteps` steps rather than one.
    public var ttftMs: Int
    public var ttftSteps: Int
    public var decodeMs: Int
    public var decodeTokens: Int

    public init?(_ value: JSONValue?) {
        guard let value, let turns = value["turns"]?.intValue else { return nil }
        self.turns = turns
        steps = value["steps"]?.intValue ?? 0
        llmMs = value["llmMs"]?.intValue ?? 0
        toolMs = value["toolMs"]?.intValue ?? 0
        ttftMs = value["ttftMs"]?.intValue ?? 0
        ttftSteps = value["ttftSteps"]?.intValue ?? 0
        decodeMs = value["decodeMs"]?.intValue ?? 0
        decodeTokens = value["decodeTokens"]?.intValue ?? 0
    }

    /// Mean time to first token, or nil before there is one to average.
    public var averageTtftMs: Int? {
        ttftSteps > 0 ? ttftMs / ttftSteps : nil
    }

    /// Output tokens per second while decoding, or nil before decoding happened.
    public var tokensPerSecond: Double? {
        decodeMs > 0 ? Double(decodeTokens) / (Double(decodeMs) / 1000) : nil
    }
}

/// What has been paid for, in tokens.
public struct TokenUsage: Equatable, Sendable {
    public var uncachedInput: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init?(_ value: JSONValue?) {
        guard let value, value["outputTokens"] != nil || value["uncachedInputTokens"] != nil else { return nil }
        uncachedInput = value["uncachedInputTokens"]?.intValue ?? 0
        output = value["outputTokens"]?.intValue ?? 0
        cacheRead = value["cacheReadTokens"]?.intValue ?? 0
        cacheWrite = value["cacheWriteTokens"]?.intValue ?? 0
    }

    public var totalInput: Int { uncachedInput + cacheRead + cacheWrite }

    /// Share of input served from cache. Nil when nothing went in, rather than
    /// zero — "no requests yet" and "every request missed" are not the same
    /// thing and a 0% that means the first is misleading.
    public var cacheHitRate: Double? {
        totalInput > 0 ? Double(cacheRead) / Double(totalInput) : nil
    }
}

/// Where the context window has gone.
public struct ContextBreakdown: Equatable, Sendable {
    public var system: Int
    public var tools: Int
    public var messages: Int

    public init?(_ value: JSONValue?) {
        guard let value, value["systemTokens"] != nil || value["messageTokens"] != nil else { return nil }
        system = value["systemTokens"]?.intValue ?? 0
        tools = value["toolsTokens"]?.intValue ?? 0
        messages = value["messageTokens"]?.intValue ?? 0
    }

    public var total: Int { system + tools + messages }
}

/// How much the agent is allowed to touch, and what else it could be set to.
///
/// Arrives per session in the `permissions` projection, and it really is
/// per session: the machine folds it from that session's own log, so switching
/// one conversation leaves every other one where it was. Two different things
/// wear this shape — a session's current mode, and the mode new conversations
/// start in (read from the machine's settings, and the only one that is
/// machine-wide).
public struct PermissionChoice: Equatable, Sendable {
    public struct Option: Identifiable, Equatable, Sendable {
        public var id: String { value }
        public var value: String
        public var name: String
    }

    public var options: [Option]
    public var current: String

    public init?(_ value: JSONValue?) {
        guard let value, let current = value["currentValue"]?.stringValue else { return nil }
        self.current = current
        options = (value["options"]?.arrayValue ?? []).compactMap { entry in
            guard let raw = entry["value"]?.stringValue else { return nil }
            return Option(value: raw, name: entry["name"]?.stringValue ?? raw)
        }
    }

    /// The presets that can be switched to. `custom` is excluded, and is not a
    /// preset: the machine adds it to `options` when a session's sandbox and
    /// approval settings match no preset — a session composed that way, or one
    /// whose knobs were set individually — so it is a state to display and
    /// never a name to send back. `/permission custom` is refused.
    public var choices: [Option] {
        options.filter { $0.value != "custom" }
    }

    /// The label to show for a raw value. The machine sends the raw string as
    /// the name too, so this is where `danger-full-access` becomes something
    /// worth reading on a phone.
    public static func label(for value: String) -> String {
        switch value {
        case "read-only": return "Read only"
        case "workspace-write": return "Workspace write"
        case "danger-full-access": return "Full access"
        case "custom": return "Custom"
        default: return value
        }
    }

    /// What the choice actually permits, in one line.
    public static func detail(for value: String) -> String {
        switch value {
        case "read-only": return "Look, don’t touch. Every write asks first."
        case "workspace-write": return "Edit inside the working folder without asking. Anything outside it still asks."
        case "danger-full-access": return "No sandbox and no questions. Everything your account can do, it can do."
        case "custom": return "This conversation’s sandbox and approval settings match none of the presets, so there is no name for them."
        default: return ""
        }
    }
}

// MARK: - Subagents

/// One child the agent spawned to do something on its own.
///
/// A subagent is a real session with its own log, which is why opening one
/// needs nothing new — `session.history` serves it like any other. What it does
/// *not* have is a row in `session.list`, which hides subagents on purpose. So
/// without this the work is invisible: the parent shows a tool call that sits
/// there for four minutes and no way to see what is happening inside it.
public struct SubagentChild: Identifiable, Equatable, Sendable {
    /// Whether the child can be talked to again, or ran once and is done.
    public enum Mode: String, Equatable, Sendable {
        case oneShot = "one-shot"
        case continuable
    }

    public var id: String
    /// The label from the child's descriptor. A continuable child always has
    /// one; a one-shot child may not, and then there is only the mode to show.
    public var label: String?
    public var mode: Mode
    /// `running` means live in the machine's session store, `inactive` means it
    /// exists only in persistence. Neither says whether it *succeeded* — the
    /// machine is explicit that this is activity, not outcome, so the UI must
    /// not draw a tick from it.
    public var running: Bool
    /// Whether this child spawned children of its own.
    public var hasChildren: Bool
    /// Time across settled turns, plus the open one when there is one.
    public var elapsed: TimeInterval?

    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return mode == .continuable ? "Subagent" : "One-shot task"
    }

    /// - Parameters:
    ///   - value: one `entries[]` element from `subagent.list`.
    ///   - timing: the child's `subagentTiming` projection, when the caller has it.
    public init?(_ value: JSONValue, timing: JSONValue? = nil) {
        // `diagnostic` entries describe a child the machine could not interpret.
        // They are not children and pretending otherwise would put a row on
        // screen that cannot be opened.
        guard value["kind"]?.stringValue == "child",
              let id = value["id"]?.stringValue,
              let mode = Mode(rawValue: value["mode"]?.stringValue ?? "") else { return nil }
        self.id = id
        self.mode = mode
        label = value["label"]?.stringValue
        running = value["activity"]?.stringValue == "running"
        hasChildren = value["hasChildren"]?.boolValue ?? false

        guard let timing else {
            elapsed = nil
            return
        }
        let settled = (timing["settledMs"]?.doubleValue ?? 0) / 1000
        // An open turn contributes the span folded into this cut so far, which
        // is why a running child's number keeps growing between refreshes.
        let open = timing.path("active", "through")?.doubleValue
            .flatMap { through in
                timing.path("active", "since")?.doubleValue.map { (through - $0) / 1000 }
            } ?? 0
        elapsed = settled + open > 0 ? settled + open : nil
    }
}
