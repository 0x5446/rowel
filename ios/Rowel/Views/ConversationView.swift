/// One conversation.
///
/// The screen people will spend all their time on. Three bands: a header that
/// answers "where am I and what is it doing", the transcript, and the composer.
/// Anything that blocks the agent slots in between the last two, so the thing
/// waiting on a person is always directly above their thumb.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ConversationView: View {
    let session: MachineSession
    let sessionId: String
    /// Push another conversation. Supplied by whoever owns the navigation path;
    /// this view knows a session id, not how the app is navigated.
    var onOpen: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var conversation: Conversation?
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showModels = false
    @State private var showInfo = false
    @State private var archiving = false
    @State private var showTrace = false
    @State private var showSubagents = false
    /// Set by the trace, consumed by the transcript's scroll reader.
    @State private var jumpTo: String?
    /// Set when a branch succeeds, so the view can offer to follow it.
    @State private var forked: String?
    /// Whether the transcript is following its own end, and the reading-back
    /// rules that decide it (see `FollowState`).
    @State private var follow = FollowState()
    /// When the transcript was last pulled to its end, for `follow`.
    @State private var followedAt = Date.distantPast
    /// Per-conversation, because attachment ids are only meaningful inside one.
    @State private var attachments: AttachmentLoader

    /// The only explicit init, and it exists for one parameter: `atBottom` is
    /// private view state whose false branch is only reachable through a real
    /// drag, which a unit test cannot perform. Stating the post-drag world at
    /// construction lets a responsiveness test compare "following the tail"
    /// against "scrolled away" on identical data. The default is the shipped
    /// behavior; the app never passes this.
    init(
        session: MachineSession,
        sessionId: String,
        onOpen: ((String) -> Void)? = nil,
        initiallyAtBottom: Bool = true
    ) {
        self.session = session
        self.sessionId = sessionId
        self.onOpen = onOpen
        _follow = State(initialValue: FollowState(follows: initiallyAtBottom))
        _attachments = State(initialValue: AttachmentLoader(harness: session.harness, sessionId: sessionId))
    }

    var body: some View {
        // Only for `room`: how much height the screen actually offers, which is
        // what caps the interrupt band. See `ceiling`.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                if let conversation {
                    if !conversation.todos.isEmpty {
                        TodoStrip(todos: conversation.todos)
                    }
                    transcript(conversation)
                    footer(conversation, room: proxy.size.height)
                } else {
                    Placeholder(icon: "ellipsis", title: "Opening…")
                }
            }
        }
        .background(Palette.paper)
        .environment(attachments)
        .navigationBarTitleDisplayMode(.inline)
        // Without this the bar is transparent and the transcript slides under
        // the title and the clock. A conversation is a wall of text; there is
        // always something up there to collide with.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.regularMaterial, for: .navigationBar)
        .toolbar { toolbar }
        .task {
            let held = session.conversation(sessionId)
            conversation = held
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task { await session.rename(sessionId: sessionId, title: renameText) }
            }
        }
        .sheet(isPresented: $showModels) {
            ModelPicker(session: session, sessionId: sessionId)
        }
        .sheet(isPresented: $showSubagents) {
            if let conversation {
                SubagentsView(session: session, conversation: conversation) { childId in
                    onOpen?(childId)
                }
            }
        }
        .sheet(isPresented: $showTrace) {
            if let conversation {
                TraceView(conversation: conversation) { itemId in
                    jumpTo = itemId
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            SessionInfoView(sessionId: sessionId)
                .environment(session)
        }
        .confirmationDialog("Archive this conversation?", isPresented: $archiving, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                Task {
                    await session.archive(sessionId: sessionId)
                    dismiss()
                }
            }
        } message: {
            Text("It leaves the list on every device. Nothing is deleted — the Mac can bring it back.")
        }
        .alert("Branched", isPresented: Binding(get: { forked != nil }, set: { if !$0 { forked = nil } })) {
            Button("Stay here", role: .cancel) { forked = nil }
            Button("Open it") {
                if let forked { onOpen?(forked) }
                forked = nil
            }
        } message: {
            Text("A copy of this conversation up to now. What you do there does not touch this one.")
        }
        .overlay(alignment: .top) { ProblemBanner(session: session) }
    }

    // MARK: - Transcript

    private func transcript(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.gap) {
                    header(conversation)

                    if conversation.hasMore {
                        Button {
                            Task { await session.loadOlder(conversation) }
                        } label: {
                            if conversation.loading {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load earlier messages")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Metrics.tight)
                    }

                    ForEach(conversation.items) { item in
                        TranscriptItem(item: item)
                            .id(item.id)
                    }

                    if conversation.running, conversation.items.last.map(stillOpen) != true {
                        Thinking().padding(.leading, 2)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Anchor.bottom)
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.vertical, Metrics.gap)
            }
            // The open position, stated to the layout instead of asked for
            // after it. `scrollTo` on the way in cannot work: it runs inside
            // the same layout pass that is still building the content it wants
            // to scroll to, so a conversation opened at the top of its own
            // history and stayed there until the reader dragged it down — the
            // "I have to scroll to the bottom every time" report. An anchor is
            // part of the layout, so the first frame is already the last line.
            //
            // The open position, stated to the layout rather than asked for
            // after it. `scrollTo` on the way in cannot work: it runs inside
            // the layout pass that is still building the content it means to
            // scroll to, so a conversation opened at the top of its own history
            // and stayed there until the reader dragged it down. An anchor is
            // part of layout, so the first frame is already the last line.
            //
            // Following *is* this anchor: pinned to the end while the reader is
            // there, gone the moment they drag back, which is what stops a
            // streaming answer from sliding in under a thumb that is reading.
            .defaultScrollAnchor(follow.follows ? .bottom : nil)
            .scrollDismissesKeyboard(.interactively)
            // A drag already dismisses; a tap did not, and a tap is what
            // someone does when they have finished typing and want to read.
            // `simultaneousGesture` so the tool cards and links underneath
            // still receive their own taps.
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            .overlay(alignment: .bottomTrailing) {
                if !follow.follows {
                    Button {
                        follow.reachedEnd()
                        withAnimation { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 34, height: 34)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().stroke(Palette.line, lineWidth: 0.5))
                    }
                    .padding(Metrics.gap)
                }
            }
            .onChange(of: conversation.items.count) { _, _ in
                follow(proxy, force: true)
            }
            .onChange(of: lastLength(conversation)) { _, _ in
                // Streaming grows the last bubble without changing the count, so
                // following along needs its length too.
                follow(proxy)
            }
            .onChange(of: conversation.queue.count) { old, new in
                guard new > old else { return }
                follow(proxy, force: true)
            }
            .onAppear {
                follow(proxy, force: true)
            }
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    // Dragging downward means reading back; stop chasing the tail
                    // until the person returns to it.
                    follow.drag(value.translation.height)
                }
            )
            .onChange(of: conversation.running) { _, running in
                // A turn that starts is the reader sending something: their own
                // words are about to land, so they are at the end by definition.
                if running { follow.reachedEnd() }
                // A transcript left a line short of its own answer reads as a
                // bug, and the last delta of a turn can land unnoticed.
                if !running { follow(proxy, force: true) }
                // A turn that just ended is the moment a child list is most
                // likely to have changed and least likely to be mid-write.
                if !running, conversation.consumeSubagentsStale() {
                    Task { await session.loadSubagents(conversation) }
                }
            }
            .onChange(of: jumpTo) { _, target in
                guard let target else { return }
                // Stop chasing the tail, or the next streamed chunk would yank
                // the view straight back down from wherever we just landed.
                follow.drag(ConversationView.jumpAway)
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                jumpTo = nil
            }
        }
    }

    private enum Anchor: Hashable { case bottom }

    /// How far landing on a traced item counts as reading back. Past the
    /// reading-back threshold, so the tail stops chasing the reader there.
    private static let jumpAway: CGFloat = 100

    /// Pull the transcript to its end, at most once every `followInterval`.
    ///
    /// Two things keep the tail on screen, and they are not redundant. The
    /// scroll view's bottom anchor (`defaultScrollAnchor`) is part of layout: it
    /// places the content at its end when it first opens, and holds it there
    /// while the reader is at the end. This is the other half — an explicit
    /// scroll on the changes that grow the content, at most ten a second.
    /// Measured, not assumed: with the anchor alone, a streamed answer left the
    /// end 234 points below the fold inside a full test run, and `StreamFollowsTests`
    /// is what caught it.
    ///
    /// What it must not go back to is one `scrollTo` per streamed delta — two
    /// hundred a second from a fast model. Each call makes the lazy stack lay
    /// itself out to the end to find the anchor it is sent to: measured on the
    /// starvation rig at the rate this harness streams (condition K, 200 chunks
    /// a second into a 190 KB open bubble), that cost 42% of all frames and left
    /// gaps of a third of a second, and a TestFlight build was killed by iOS for
    /// spending its whole ten-second scene-update allowance inside
    /// `AttributeGraph`.
    private func follow(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard follow.shouldFollow() else { return }
        let now = Date()
        guard force || now.timeIntervalSince(followedAt) >= ConversationView.followInterval else { return }
        followedAt = now
        proxy.scrollTo(Anchor.bottom, anchor: .bottom)
    }

    /// How often growing content may pull the view down.
    private static let followInterval: TimeInterval = 0.1

    private func lastLength(_ conversation: Conversation) -> Int {
        guard case .assistant(let turn)? = conversation.items.last else { return 0 }
        return turn.text.count + turn.reasoning.count
    }

    private func stillOpen(_ item: ConversationItem) -> Bool {
        switch item {
        case .assistant(let turn): return !turn.complete
        case .tool(let card): return card.running
        default: return false
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ conversation: Conversation) -> some View {
        if !conversation.loaded {
            // Until the first page lands there is nothing to draw, and drawing
            // nothing reads as "this conversation is empty" rather than "still
            // fetching". A long history is exactly when this matters most.
            HStack(spacing: Metrics.tight) {
                Thinking()
                Text("Loading this conversation…")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Metrics.gutter)
        } else if conversation.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing here yet")
                    .font(.system(size: 17, weight: .semibold))
                Text(conversation.cwd.map { "Working in \(Format.path($0, home: session.machineInfo?.cwd))" } ?? "Say what you want done.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, Metrics.gutter)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(_ conversation: Conversation, room: CGFloat) -> some View {
        VStack(spacing: Metrics.tight) {
            if hasInterrupt(conversation) {
                band(conversation, room: room)
            }
            Composer(
                running: conversation.running,
                planning: conversation.planning,
                enabled: session.harnessReachable,
                commands: conversation.commands,
                onSend: { text, images in
                    follow.reachedEnd()
                    Task { await session.send(sessionId: sessionId, text: text, images: images) }
                },
                onStop: {
                    Task { await session.cancel(sessionId: sessionId) }
                }
            )
            StatStrip(conversation: conversation) { showInfo = true }
        }
        .animation(.easeInOut(duration: 0.2), value: session.approvals[sessionId])
        .animation(.easeInOut(duration: 0.2), value: session.questions[sessionId])
    }

    // MARK: - The interrupt band

    private func hasInterrupt(_ conversation: Conversation) -> Bool {
        session.approvals[sessionId] != nil
            || session.questions[sessionId] != nil
            || !conversation.queue.isEmpty
    }

    /// Everything that stands between the transcript and the composer: the two
    /// cards the agent stops on, and the messages waiting behind a running turn.
    ///
    /// Bounded and scrollable, because as a plain `VStack` it was neither. The
    /// question card is as tall as the questions it carries — three questions
    /// with ten described options is an ordinary request, and taller than the
    /// screen — so the column overflowed at both ends: the first options slid
    /// under the navigation bar, and the composer and the card's own Send button
    /// were pushed past the bottom edge, into the strip iOS reserves for the home
    /// gesture, where a tap belongs to the system and not to the button. Both
    /// symptoms, one cause: nothing in the band could scroll or be capped.
    ///
    /// The band now measures itself, through `CappedScroll`: as tall as its
    /// content until that is more than `ceiling(room)` allows, at which point it
    /// scrolls inside. The composer and the stat strip are outside it and always
    /// fit. A question card keeps its own answer button pinned below its own
    /// questions, so the thing being asked for is never the thing off screen.
    @ViewBuilder
    private func band(_ conversation: Conversation, room: CGFloat) -> some View {
        CappedScroll(ceiling: ceiling(room)) {
            VStack(spacing: Metrics.tight) {
                if let approval = session.approvals[sessionId] {
                    ApprovalCard(request: approval) { allow in
                        Task { await session.answer(approval: approval, allow: allow) }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let question = session.questions[sessionId] {
                    QuestionCard(request: question) { answers in
                        Task { await session.answer(question: question, answers: answers) }
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if !conversation.queue.isEmpty {
                    QueueStrip(
                        queue: conversation.queue,
                        onRemove: { item in
                            Task {
                                try? await session.harness.updateQueue(sessionId: sessionId, itemId: item.id, action: .remove)
                            }
                        },
                        onPromote: { item in
                            Task { await session.promote(sessionId: sessionId, item: item) }
                        }
                    )
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
    }

    /// The most of the screen the interrupt band may take.
    ///
    /// Half the room, capped: the composer and the stat strip below it are small
    /// and fixed, and the transcript above should keep the larger half — the
    /// transcript is how someone decides what to answer. The floor keeps a tall
    /// card from being squeezed into a sliver on a small phone, where scrolling
    /// inside it is the only way to reach the answer.
    private func ceiling(_ room: CGFloat) -> CGFloat {
        min(ConversationView.bandCeiling, max(180, room * 0.5))
    }

    /// A question card past this is a wall of text however tall the phone is.
    private static let bandCeiling: CGFloat = 380

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(conversation?.title ?? summary?.displayTitle ?? "Conversation")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Button {
                        showModels = true
                    } label: {
                        HStack(spacing: 3) {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Change model")
                    .accessibilityIdentifier("conversation.model")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    renameText = conversation?.title ?? ""
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    showModels = true
                } label: {
                    Label("Model", systemImage: "cpu")
                }
                Button {
                    showTrace = true
                } label: {
                    Label("Trace", systemImage: "list.bullet.indent")
                }
                if let children = conversation?.subagents, !children.isEmpty {
                    // Only when there are any. An always-present row that opens
                    // an empty screen teaches people to stop tapping it.
                    Button {
                        showSubagents = true
                    } label: {
                        Label("Subagents (\(children.count))", systemImage: "person.2")
                    }
                }
                Button {
                    Task {
                        if let branched = await session.fork(sessionId: sessionId) {
                            forked = branched
                        }
                    }
                } label: {
                    Label("Branch from here", systemImage: "arrow.triangle.branch")
                }
                if conversation?.running == true {
                    Button(role: .destructive) {
                        Task { await session.cancel(sessionId: sessionId) }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                }
                Button(role: .destructive) {
                    archiving = true
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                Section {
                    Button {
                        showInfo = true
                    } label: {
                        // The context percentage rides on the label rather than
                        // being a dead row of its own: it is the number worth
                        // seeing without opening anything, and it doubles as the
                        // reason to open this.
                        if let fraction = conversation?.contextFraction {
                            Label("Session · context \(Int((fraction * 100).rounded()))%",
                                  systemImage: "gauge.with.dots.needle.bottom.50percent")
                        } else {
                            Label("Session", systemImage: "gauge.with.dots.needle.bottom.50percent")
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Conversation options")
            .accessibilityIdentifier("conversation.menu")
        }
    }

    private var summary: SessionSummary? {
        session.sessions.first { $0.id == sessionId }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let cwd = conversation?.cwd ?? summary?.cwd {
            parts.append((cwd as NSString).lastPathComponent)
        }
        // Named even when unknown: a session that has never run has no
        // `request/header` to learn it from, and that is the same session whose
        // model is most likely to be the wrong one.
        parts.append(conversation?.modelName ?? "Choose model")
        if let fraction = conversation?.contextFraction, fraction > 0.7 {
            parts.append("context \(Int(fraction * 100))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The numbers dsh keeps under its own composer, sized for a phone.
///
/// These were built and then buried in a menu, which is the same as not having
/// built them: the first person to use it did not find them. The web UI keeps
/// seven fields on one line because it has the width; a phone has room for
/// three, so this shows the three that change what someone does next and puts
/// the rest one tap away.
///
/// Which three depends on what is happening. While a turn runs, the question is
/// "is this going anywhere" — elapsed and speed. When it is idle, it is "how
/// much room is left and what has this cost". Context comes first either way,
/// because it is the only one with a cliff at the end of it.
private struct StatStrip: View {
    let conversation: Conversation
    let onTap: () -> Void

    var body: some View {
        if let fields = fields {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { index, field in
                        if index > 0 {
                            Text("·")
                                .foregroundStyle(.quaternary)
                                .padding(.horizontal, 6)
                        }
                        Text(field.text)
                            .foregroundStyle(field.warn ? AnyShapeStyle(Palette.warn) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.quaternary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, Metrics.gutter)
                .padding(.bottom, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.stats")
            .accessibilityLabel("Session statistics")
        }
    }

    private struct Field {
        var text: String
        var warn = false
    }

    /// Nil before the session has produced anything worth counting — an empty
    /// strip of zeroes under a blank conversation is noise with a chevron on it.
    private var fields: [Field]? {
        var made: [Field] = []
        if let fraction = conversation.contextFraction {
            made.append(Field(text: "ctx \(Int((fraction * 100).rounded()))%", warn: fraction > 0.8))
        }
        if let stats = conversation.stats, stats.turns > 0 {
            if conversation.running {
                if let rate = stats.tokensPerSecond, rate > 0 {
                    made.append(Field(text: "\(Int(rate.rounded())) tok/s"))
                }
                made.append(Field(text: Format.duration(ms: stats.llmMs)))
            } else {
                made.append(Field(text: "\(stats.turns) turns · \(stats.steps) steps"))
                if let tokens = conversation.tokens {
                    made.append(Field(text: "\(Format.tokens(tokens.totalInput))↑ \(Format.tokens(tokens.output))↓"))
                }
            }
        }
        return made.isEmpty ? nil : made
    }
}
