/// The list of conversations on one machine.
///
/// The home screen. Its job is to get someone into the right conversation in one
/// tap, so the rows carry the two things that decide that — what it is about, and
/// whether it needs them right now — and nothing else.

import SwiftUI

struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    let session: MachineSession
    @Binding var path: [String]

    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    /// Why the machine could not run a full-text search, when it could not.
    ///
    /// Shown rather than swallowed. The first version used `try?`, which turned
    /// "this Mac has the session index switched off" into an empty list — the
    /// app telling someone their words matched nothing when the truth was that
    /// it never asked.
    @State private var searchUnavailable: String?
    @State private var picking = false
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    /// The workspace whose name is being edited, and what it is being changed
    /// to. Held as the whole group rather than an id so the alert can say which
    /// one it is about even as the list underneath it changes.
    @State private var renamingGroup: SessionGroup?
    @State private var groupName = ""
    @State private var deletingGroup: SessionGroup?

    /// Collision-aware machine name for prose. See `MachineLabel`.
    private var machineLabel: String {
        model.label(for: session.machine).prose
    }

    /// The one structured verdict a failed dial can carry — see `DialDiagnosis`.
    private var relaySaysOffline: Bool {
        if case .waiting(_, _, let diagnosis) = session.status {
            return diagnosis?.relaySaysOffline == true
        }
        return false
    }

    /// Where the most recently touched conversation is, if any.
    ///
    /// Most *recent* rather than most *used*, which is what the folder browser
    /// ranks its shortcuts by. The two answer different questions: the browser
    /// is showing places worth offering, this is guessing where the next
    /// conversation belongs — and the honest guess is wherever the last one
    /// was. A blank conversation counts; it was still a deliberate choice of
    /// folder even if nothing was said in it.
    private var lastFolder: String? { lastFolderIn(session.sessions) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            NewButton(
                lastFolder: lastFolder,
                resume: { folder in
                    Task {
                        if let id = await session.createSession(cwd: folder, preset: nil) {
                            path.append(id)
                        }
                    }
                },
                browse: { picking = true }
            )
                .padding(Metrics.gutter)
                .opacity(session.harnessReachable ? 1 : 0.4)
                .disabled(!session.harnessReachable)
        }
        .background(Palette.paper)
        .navigationTitle("")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search conversations")
        .task(id: query) { await runSearch() }
        .refreshable { await session.refreshSessions() }
        .sheet(isPresented: $picking) {
            DirectoryPicker(session: session) { cwd, preset in
                Task {
                    if let id = await session.createSession(cwd: cwd, preset: preset) {
                        path.append(id)
                    }
                }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let target = renaming {
                    Task { await session.rename(sessionId: target.id, title: renameText) }
                }
                renaming = nil
            }
        }
        .alert("Rename workspace", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $groupName)
            Button("Cancel", role: .cancel) { renamingGroup = nil }
            Button("Save") {
                if let target = renamingGroup {
                    Task { await session.renameWorkspace(target.id, title: groupName) }
                }
                renamingGroup = nil
            }
        } message: {
            // Said because it is not obvious from a phone: this is the Mac's own
            // sidebar, and the name changes there too.
            Text("This is the name on the Mac’s sidebar as well.")
        }
        .confirmationDialog(
            "Stop grouping by \(deletingGroup?.title ?? "this folder")?",
            isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove workspace", role: .destructive) {
                guard let target = deletingGroup else { return }
                deletingGroup = nil
                Task {
                    // Not undoable from here: re-registering the same folder
                    // mints a new workspace that adopts nothing, so the grouping
                    // is gone for good even though nothing else is.
                    guard await lock.confirm("Remove the \(target.title) workspace on your Mac.") else { return }
                    await session.deleteWorkspace(target.id)
                }
            }
            Button("Cancel", role: .cancel) { deletingGroup = nil }
        } message: {
            // Checked against the machine's own contract rather than assumed.
            // Deleting a workspace removes the grouping and nothing else: the
            // folder, the files in it, and every conversation stay exactly as
            // they were, and the conversations reappear under Ungrouped.
            Text("The folder, its files, and \(held) stay exactly as they are — they just move to Ungrouped. Only the grouping goes.")
        }
        .overlay(alignment: .top) {
            ProblemBanner(session: session)
        }
    }

    /// What the workspace about to be removed is holding, for the confirmation.
    /// The count is the reassuring part — someone is about to tap a red button
    /// over a section with forty conversations under it.
    private var held: String {
        let count = deletingGroup?.sessions.count ?? 0
        return count == 1 ? "the conversation in it" : "all \(count) conversations in it"
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            StatusLine(session: session)
            if rows.isEmpty {
                empty
            } else {
                let arrangement = board
                List {
                    // Flat while searching, on purpose. A search is already a
                    // way of crossing the folders, and putting three results
                    // behind three headers would hide them behind the very
                    // structure the person just chose to ignore.
                    //
                    // Flat, too, when there is nothing to divide by: one
                    // workspace, none at all, or a dsh too old to have
                    // `workspace.list`. That is the same list this screen drew
                    // before grouping existed, which is what makes the failure
                    // path unremarkable rather than a special case.
                    if query.isEmpty, arrangement.grouped {
                        sections(arrangement)
                    } else {
                        ForEach(rows) { row($0) }
                    }
                }
                .listStyle(.plain)
                .listSectionSpacing(Metrics.tight)
                .scrollContentBackground(.hidden)
                .background(Palette.paper)
                .accessibilityIdentifier("sessions.list")
                // Under the results, not over them: what is on screen is real
                // and useful, and what is missing is only the message-content
                // half. A banner would imply the list itself is untrustworthy.
                // The compose button floats over the bottom-trailing corner, so
                // the list has to end above it. Without this the last row sits
                // under the button and cannot be read or tapped.
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 72)
                }
            }
        }
    }

    /// Whether the list has simply not arrived yet.
    ///
    /// Three states used to be one. Dialling, fetching, and failing all ended
    /// up at "Can't reach this Mac", because the only question asked was
    /// `!isOnline` — and for the first second of every launch that is true for
    /// the most ordinary reason there is. Failure keeps a loud screen; this
    /// covers everything that is just work in progress. Two gaps closed since
    /// the first version, both found by launching the app and watching:
    ///
    /// - The early retries. A first dial that fails — one flaky address is
    ///   enough — put the app in `waiting` for half a second, and this said
    ///   "Can't reach" over a connection that succeeds on the next attempt.
    ///   The banner already reports each failure and offers Retry; the
    ///   full-screen verdict now needs the backoff to have grown, which takes
    ///   several consecutive failures. A verdict reached in 300ms is a guess
    ///   wearing a verdict's clothes.
    /// - The moment after connecting. Online, list not yet asked for: every
    ///   claim below ("dsh isn't running", "no conversations") was rendered in
    ///   that gap on facts that had not arrived.
    private var starting: Bool {
        guard query.isEmpty, session.sessions.isEmpty else { return false }
        switch session.status {
        case .idle, .connecting:
            return true
        case .waiting(_, let retryIn, _):
            // Backoff doubles from half a second; single digits mean only a
            // failure or two so far. At the ceiling it has genuinely tried.
            return retryIn < 8
        case .online:
            return session.listing || !session.everListed || !session.harnessKnown
        case .refused:
            return false
        }
    }

    @ViewBuilder
    private var empty: some View {
        if starting {
            // Not a placeholder, and not "Can't reach" either. A cold start
            // spends its first second dialling, and both of those read as a
            // verdict: one says there is nothing here, the other says something
            // is broken, and at 300ms neither is known. Rows-shaped grey says
            // the only true thing — the list is on its way.
            SessionSkeleton()
        } else if !query.isEmpty, searchUnavailable != nil {
            // Not "nothing matched" — the machine never ran the search, so no
            // claim about matches is warranted. And the remedy is four lines of
            // YAML, so it belongs here rather than in a support page: dsh ships
            // with the index off for everyone, which makes this the single most
            // likely thing a new user sees when they first tap search.
            Placeholder(
                icon: "magnifyingglass",
                title: "Search is off on this Mac",
                detail: """
                dsh ships with its session index disabled. To switch it on, add this to \
                ~/.dsh/profiles/web/cordis.patch.yml and restart dsh:

                - id: session-query-sqlite
                  config:
                    path: ~/.dsh/session-query.sqlite
                    openAt: first-search
                """
            )
        } else if !query.isEmpty {
            Placeholder(icon: "magnifyingglass", title: "Nothing matched", detail: "Try a word from the conversation itself.")
        } else if !session.isOnline {
            // Narrowed only as far as the evidence reaches. The relay saying
            // "that machine is offline" (close code 4404) is the one verdict
            // strong enough to name a layer: the relay answered, so the
            // network works, and the machine's Bridle is not connected to it.
            // Anything weaker keeps the honest three-way sentence — with no
            // tunnel there is no information about the far side, and the last
            // time this screen guessed, dsh was fine and the Bridle had
            // stopped.
            if relaySaysOffline {
                Placeholder(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Can’t reach \(machineLabel)",
                    detail: "Bridle isn’t connected to the relay — the Mac is asleep, or Bridle isn’t running on it."
                ) {
                    RescueCard(tier: .bridleDown, session: session)
                }
            } else {
                Placeholder(
                    icon: "antenna.radiowaves.left.and.right.slash",
                    title: "Can’t reach \(machineLabel)",
                    detail: "The Mac is asleep, off your network, or Bridle isn’t running on it."
                ) {
                    RescueCard(tier: .unknown, session: session)
                }
            }
        } else if !session.harnessReachable {
            Placeholder(
                icon: "bolt.horizontal.circle",
                title: "dsh isn’t running",
                detail: session.harnessDetail ?? "Start the agent on \(machineLabel) and this fills in by itself."
            ) {
                RescueCard(tier: .harnessDown, session: session)
            }
        } else {
            Placeholder(
                icon: "bubble.left.and.text.bubble.right",
                title: "No conversations yet",
                detail: "Start one and pick the folder to work in."
            ) {
                Button("New conversation") { picking = true }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.horizontal, Metrics.gutter * 2)
            }
        }
    }

    // MARK: - Sections

    /// The list arranged into workspaces, with whatever is stuck lifted clear.
    ///
    /// Recomputed per render rather than cached: it is a couple of dictionary
    /// passes over a few dozen rows, and a cache would need invalidating on
    /// every event that touches a session, an approval, or a workspace — three
    /// chances to show something stale in exchange for microseconds.
    private var board: SessionBoard {
        SessionBoard(
            sessions: session.sessions,
            workspaces: session.workspaces,
            waitingOn: Set(session.approvals.keys).union(session.questions.keys),
            archived: session.archivedSessionIds
        )
    }

    @ViewBuilder
    private func sections(_ arrangement: SessionBoard) -> some View {
        // Above everything and outside every fold. This is the one thing on the
        // screen that is not filing — a tool waiting on a tap does not care
        // which folder it is in, and burying it under a collapsed header would
        // defeat the entire reason for carrying this app around.
        if !arrangement.waiting.isEmpty {
            Section {
                ForEach(arrangement.waiting) { row(Row(summary: $0, snippet: nil)) }
            } header: {
                GroupHeader(title: "Needs you", count: arrangement.waiting.count, open: nil, tint: Palette.warn) {}
            }
        }
        ForEach(arrangement.groups) { group in
            let open = session.folds.isOpen(group.id, unlessRemembered: group.id == arrangement.openByDefault)
            Section {
                if open {
                    ForEach(group.sessions) { row(Row(summary: $0, snippet: nil)) }
                }
            } header: {
                GroupHeader(title: group.title, count: group.sessions.count, open: open) {
                    // Short and unspringy. A fold near the top of the list
                    // moves everything under it, and a bouncy curve turns that
                    // into the whole screen lurching.
                    withAnimation(.easeOut(duration: 0.2)) {
                        session.folds.set(group.id, open: !open)
                    }
                }
                // Long press rather than a swipe: a section header is not a row
                // and cannot carry swipe actions, and rename and remove are both
                // things done once, deliberately, not while scrolling past.
                //
                // Attached only to real workspaces, and by branching rather than
                // by an empty menu body — a `contextMenu` with nothing in it
                // still opens on long press, and a blank popup reads as broken.
                // "Ungrouped" is this app's own word for what nothing claims;
                // there is no workspace behind it to rename or remove.
                .modifier(WorkspaceHeaderActions(
                    group: group,
                    rename: {
                        groupName = group.title
                        renamingGroup = group
                    },
                    remove: { deletingGroup = group }
                ))
            }
        }
    }

    // MARK: - Rows

    private struct Row: Identifiable {
        var id: String { summary.id }
        var summary: SessionSummary
        var snippet: String?
    }

    @ViewBuilder
    private func row(_ item: Row) -> some View {
        Button {
            path.append(item.summary.id)
        } label: {
            SessionRow(
                summary: item.summary,
                snippet: item.snippet,
                needsYou: session.approvals[item.summary.id] != nil || session.questions[item.summary.id] != nil,
                home: session.machineInfo?.cwd
            )
        }
        // A group header is a button in the same collection view, and its title
        // is a folder name — so "the first button" and "the first thing that
        // looks like a path" both pick headers as often as rows. Tests need one
        // name that only a conversation ever carries.
        .accessibilityIdentifier("session.row")
        .listRowInsets(EdgeInsets(top: 6, leading: Metrics.gutter, bottom: 6, trailing: Metrics.gutter))
        .listRowBackground(Palette.paper)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            // Archive first, because it is the destructive-looking one and iOS
            // puts the first trailing action closest to the thumb — and because
            // filing something away is what a long list is for. It is not
            // `role: .destructive`: nothing is deleted, the log stays exactly
            // where it was, and a red button would say otherwise.
            Button {
                Task { await session.archive(sessionId: item.summary.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Palette.warn)
            Button {
                renameText = item.summary.title ?? ""
                renaming = item.summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Palette.accent)
        }
        // Rename is here as well as on the swipe so this menu is never empty:
        // the filing item below is absent for most rows, and a context menu with
        // nothing in it still opens on long press.
        .contextMenu {
            Button {
                renameText = item.summary.title ?? ""
                renaming = item.summary
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            filing(item.summary)
            Button {
                Task { await session.archive(sessionId: item.summary.id) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
        }
    }

    /// The one thing that can be done about a conversation's grouping.
    ///
    /// Not a "move to…" menu, because there is nowhere to move it to. A
    /// conversation belongs to the workspace whose folder is its own working
    /// folder, that folder never changes, and the machine refuses to file a
    /// conversation anywhere else. And no "move into…" for a folder that
    /// already has a workspace, because the board seats those on its own — the
    /// only case left is a folder nothing stands for. One tap makes the
    /// workspace, and the board seats every conversation from that folder
    /// under it, not just this row.
    @ViewBuilder
    private func filing(_ summary: SessionSummary) -> some View {
        switch session.filing(for: summary) {
        case .settled:
            EmptyView()
        case .claim(let folder):
            Button {
                Task {
                    if let failure = await session.createWorkspace(path: folder) {
                        session.problem = failure
                    }
                }
            } label: {
                Label("Group by \((folder as NSString).lastPathComponent)", systemImage: "folder.badge.plus")
            }
        }
    }

    /// Search results, when there is a query, joined against the list this screen
    /// already holds — the machine answers with ids and excerpts, and the titles
    /// and timestamps live here.
    private var rows: [Row] {
        // The same archive filter `SessionBoard` applies, because this is the
        // path taken when there is nothing to group by — a machine with one
        // workspace or none — and an archived conversation must not come back
        // just because the sections did not draw.
        let visible = session.archivedSessionIds.isEmpty
            ? session.sessions
            : session.sessions.filter { !session.archivedSessionIds.contains($0.id) }
        guard !query.isEmpty else {
            return visible.map { Row(summary: $0, snippet: nil) }
        }
        // The machine is the only search backend, deliberately. An earlier
        // version filtered titles locally as a floor when the machine could not
        // search, and that was wrong for a reason worth keeping written down:
        // the two match different things — message contents versus a title —
        // and blended into one list nobody can tell which is which, so the
        // local half quietly returns rows the machine would not have. Half a
        // search that disagrees with the machine is worse than no search that
        // says so.
        let byId = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return hits.compactMap { hit in
            guard let summary = byId[hit.id] else { return nil }
            return Row(summary: summary, snippet: hit.snippet.isEmpty ? nil : hit.snippet)
        }
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            hits = []
            return
        }
        // A keystroke-per-request would hammer the tunnel; a beat of quiet first
        // means one search per pause in typing.
        try? await Task.sleep(nanoseconds: 280_000_000)
        guard !Task.isCancelled else { return }
        searching = true
        defer { searching = false }
        do {
            hits = try await session.harness.search(query: text).hits
            searchUnavailable = nil
        } catch {
            hits = []
            // dsh says "session search is disabled: … openAt \"never\"" when the
            // index was never opened, which is a deployment choice rather than a
            // fault. Either way the local matches below still stand, so this is
            // a footnote under results and not a banner over them.
            searchUnavailable = (error as? LocalizedError)?.errorDescription
                ?? "This Mac has full-text search turned off."
        }
    }
}

/// Long-press actions for a section that stands for a real workspace.
///
/// A modifier rather than an `if` inside the menu body, because an empty
/// `contextMenu` is not the same as no `contextMenu`: the first still opens a
/// blank popup over the header. A group is either the leftovers or a workspace
/// for its whole life, so branching on it never swaps a view's identity
/// mid-flight.
private struct WorkspaceHeaderActions: ViewModifier {
    let group: SessionGroup
    let rename: () -> Void
    let remove: () -> Void

    func body(content: Content) -> some View {
        if group.isUngrouped {
            content
        } else {
            content.contextMenu {
                Button(action: rename) {
                    Label("Rename workspace", systemImage: "pencil")
                }
                Button(role: .destructive, action: remove) {
                    Label("Remove workspace", systemImage: "folder.badge.minus")
                }
            }
        }
    }
}

/// A section head: what the group is, how much is in it, and whether it is open.
///
/// The count is not decoration. Folded, this row is the only thing standing for
/// forty conversations, and a header with no number says "empty" as readily as
/// it says "collapsed".
private struct GroupHeader: View {
    let title: String
    let count: Int
    /// nil for a section that cannot fold — the one holding whatever is waiting
    /// on an answer, which has no business being hidden.
    let open: Bool?
    var tint: Color = .secondary
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: open == nil ? "hand.raised.fill" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(open == true ? 90 : 0))
                    .foregroundStyle(open == nil ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
            // Section headers are uppercased by some list styles. These are
            // folder names someone typed, and shouting them back changes what
            // they say.
            .textCase(nil)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
        // Only ever used as a section header, so it carries its own row metrics
        // rather than making both call sites restate them. The paper
        // background matters: a plain list pins headers as you scroll, and the
        // default backing would show as a grey band over the cards.
        .listRowInsets(EdgeInsets(top: 2, leading: Metrics.gutter, bottom: 2, trailing: Metrics.gutter))
        .listRowBackground(Palette.paper)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) conversations")
        .accessibilityHint(open == nil ? "" : (open == true ? "Collapses this group" : "Expands this group"))
    }
}

/// One conversation.
struct SessionRow: View {
    let summary: SessionSummary
    var snippet: String?
    var needsYou: Bool
    /// The machine's home directory, so paths read as `~/code/thing`.
    var home: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: Metrics.tight) {
                    Text(summary.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    if needsYou {
                        Pill("Needs you", color: Palette.warn, icon: "hand.raised.fill")
                    } else if summary.running {
                        Pill("Running", color: Palette.accent, icon: "circle.fill")
                    }
                }
                HStack(spacing: 6) {
                    if let cwd = summary.cwd {
                        // The path relative to home, not just its last
                        // component: everything in one workspace shares a last
                        // component, and eight rows all reading "workspace" is
                        // the same as showing nothing.
                        Text(Format.path(cwd, home: home))
                            .font(.code(11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(Format.ago(summary.updatedAt))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                if let snippet {
                    Text(snippet)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// The one action on this screen.
///
/// Tapping continues where the last conversation was, because that is almost
/// always where the next one belongs: people work in one folder for days at a
/// time, and making them confirm it every time is a question with a foregone
/// answer. Holding offers the folder browser for the times it is not.
///
/// No setting behind this. A stored "default folder" would be a second thing to
/// keep true — one that goes stale the day the folder is renamed, and that
/// nobody would think to look at when new conversations started appearing in
/// the wrong place. The last folder used is already known and cannot go stale
/// in a way the conversation list does not already show.
struct NewButton: View {
    /// Where the last conversation was, or nil on a machine with none yet.
    let lastFolder: String?
    /// Start one straight away in `lastFolder`.
    let resume: (String) -> Void
    /// Open the browser.
    let browse: () -> Void

    var body: some View {
        Button {
            if let lastFolder { resume(lastFolder) } else { browse() }
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Palette.accent, in: Circle())
                .shadow(color: Palette.accent.opacity(0.35), radius: 12, y: 4)
        }
        .accessibilityLabel(lastFolder == nil ? "New conversation" : "New conversation in \(folderName(lastFolder ?? ""))")
        // The escape hatch, and the only place the destination is stated before
        // it is used. A long press is where iOS puts the alternative to a
        // button's obvious action, and the menu says the folder out loud so the
        // shortcut is discoverable rather than merely present.
        .contextMenu {
            if let lastFolder {
                Button {
                    resume(lastFolder)
                } label: {
                    Label("Continue in \(folderName(lastFolder))", systemImage: "arrow.turn.down.right")
                }
            }
            Button {
                browse()
            } label: {
                Label("Choose a folder…", systemImage: "folder")
            }
        }
    }
}

/// Where the next conversation should start, given the ones that exist.
///
/// Most *recent* rather than most *used*, which is what the folder browser
/// ranks its shortcuts by. The two answer different questions: the browser is
/// offering places worth going, this is guessing where the next conversation
/// belongs — and the honest guess is wherever the last one was. A blank
/// conversation counts, because choosing its folder was still a choice.
///
/// Subagent sessions are excluded: their folder is the agent's own bookkeeping
/// rather than somewhere a person decided to work, and letting one win would
/// move the button's destination with nobody having touched it.
/// - Parameter sessions: every conversation the machine knows about.
/// - Returns: the folder, or nil when there is nothing to continue.
func lastFolderIn(_ sessions: [SessionSummary]) -> String? {
    sessions
        .filter { !$0.isSubagent }
        .max { $0.updatedAt < $1.updatedAt }?
        .cwd
}

/// The last path component, which is what a folder is called to a person.
/// - Parameter path: an absolute path on the machine.
/// - Returns: the folder's own name, or the path when it has no components.
func folderName(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
}

/// A transient failure, shown over whatever is on screen and dismissed by tapping
/// it or by time. Failures here are things like "that didn't send" — worth saying
/// once, not worth a modal.
/// The rescue card: what to do on the Mac, said from the phone.
///
/// Guidance only, and the card says so — the tunnel is the only channel, so
/// when the machine side is down there is nothing here that can act. What it
/// can do is put the right command under the person's eyes, with the right
/// home directory when the machine ever said one this app session. Commands
/// are spelled bare `bridle …`: the pairing sheet's install line links that
/// command onto PATH, and no npm package exists for `npx` to fetch — an
/// `npx @rowel/bridle` here would end in a registry 404 at rescue time, the
/// worst possible answer.
struct RescueCard: View {
    enum Tier {
        /// The relay answered: this machine's Bridle is not registered.
        case bridleDown
        /// The tunnel is up but the Bridle cannot reach dsh.
        case harnessDown
        /// Nothing conclusive — network, sleep, or Bridle, unranked.
        case unknown
    }

    let tier: Tier
    let session: MachineSession
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    Text(step)
                        .font(.code(12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Rowel can’t run these for you — the tunnel is the only channel, and it’s the part that’s down.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } label: {
            Label("On the Mac", systemImage: "terminal")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, Metrics.gutter * 2)
        .padding(.top, 4)
    }

    private var steps: [String] {
        let home = session.harnessInfo?.home
        let status = home.map { "ROWEL_HOME=\($0) bridle status" }
            ?? "bridle status   (multiple identities? point ROWEL_HOME at the right one)"
        switch tier {
        case .bridleDown:
            return [
                "1. \(status)",
                "2. “inside dsh” → restart dsh · “not running” → " + (home.map { "ROWEL_HOME=\($0) bridle start" } ?? "bridle start"),
            ]
        case .harnessDown:
            let port = session.harnessInfo?.port
            return [
                "Bridle is up; dsh isn’t. On the Mac:",
                port.map { "dsh web --port \($0)" } ?? "dsh web",
            ]
        case .unknown:
            return [
                "1. Is the Mac awake, and on a network?",
                "2. curl \(URL(string: session.machine.relay)?.host ?? "the relay")/healthz   (does the Mac reach the internet?)",
                "3. \(status)",
            ]
        }
    }
}

struct ProblemBanner: View {
    let session: MachineSession

    var body: some View {
        if let problem = session.problem {
            Text(problem)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, Metrics.gap)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bad, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                .padding(.horizontal, Metrics.gutter)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { session.problem = nil }
                .task(id: problem) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    session.problem = nil
                }
        }
    }
}

/// The list before the list arrives.
///
/// A cold start has a real gap in it — dial the Mac, then ask it for its
/// conversations — and the app used to fill that gap with the words "Can't
/// reach", which is both alarming and, for the ordinary case, false. What is
/// actually true at that moment is that rows are coming, and rows-shaped grey
/// is the only way to say that without making a claim.
///
/// Not animated into existence: it appears at launch, and something fading in
/// over the top of nothing reads as a second delay rather than a first one.
private struct SessionSkeleton: View {
    /// Enough to fill a phone, and varied so it reads as content rather than a
    /// progress bar someone drew badly.
    private static let widths: [CGFloat] = [0.72, 0.46, 0.85, 0.58, 0.66, 0.40, 0.78]

    @State private var dim = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SessionSkeleton.widths.enumerated()), id: \.offset) { _, width in
                HStack(spacing: Metrics.gap) {
                    VStack(alignment: .leading, spacing: 7) {
                        bar(width: width, height: 13)
                        bar(width: width * 0.55, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, 13)
            }
            Spacer(minLength: 0)
        }
        .opacity(dim ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityElement()
        .accessibilityLabel("Loading conversations")
        .accessibilityIdentifier("sessions.skeleton")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Palette.well)
                .frame(width: geometry.size.width * width, height: height)
        }
        .frame(height: height)
    }
}
