/// Choosing where a conversation happens.
///
/// A new conversation needs a working directory, and on a phone that cannot be a
/// text field — nobody types `/Users/you/code/thing` with a thumb. So it browses
/// the Mac, remembers where conversations have been started before, and puts
/// those first, because the honest distribution is that people work in four or
/// five folders and revisit them constantly.
///
/// It also answers the question this screen used to leave hanging: which section
/// of the list the conversation will turn up in. On this machine a workspace *is*
/// a folder, so picking the folder decides the grouping, and it decided it
/// silently — someone would start a conversation in a folder they had eight
/// others in and find it in the leftovers with no way to have known. That is
/// also where making a workspace lives, for the same reason: there is nothing to
/// making one but choosing a directory, and this is the screen that chooses
/// directories.

import SwiftUI

struct DirectoryPicker: View {
    let session: MachineSession
    /// The folder, and the agent preset id — nil for the machine's default.
    let onPick: (String?, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirectoryListing?
    @State private var loading = true
    @State private var problem: String?
    @State private var showHidden = false
    /// True while `workspace/create` is in flight, so the button cannot start a
    /// second one and can say it is doing something.
    @State private var claiming = false
    /// Why the folder could not become a workspace. Shown in place of the line
    /// it replaces, not over the whole screen: the browser still works and the
    /// conversation can still start here, ungrouped.
    @State private var claimProblem: String?
    /// Set when the Mac has no browsable picker at all, which is not a failure
    /// so much as a different machine — see `cannotBrowse`.
    @State private var browsingOff = false
    /// A path typed by hand, for that case.
    @State private var typed = ""
    /// The agent preset the conversation will start as. nil is the machine's
    /// default — the field is simply omitted from `session/create`.
    @State private var preset: String?

    /// Folders a conversation has already been started in, most used first.
    private var recents: [String] {
        var counts: [String: Int] = [:]
        for summary in session.sessions {
            guard let cwd = summary.cwd else { continue }
            counts[cwd, default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading && listing == nil {
                    Placeholder(icon: "folder", title: "Reading folders…")
                } else if browsingOff {
                    cannotBrowse
                } else if let problem {
                    Placeholder(icon: "exclamationmark.triangle", title: "Couldn’t browse", detail: problem) {
                        Button("Start in the default folder") { pick(nil) }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.horizontal, Metrics.gutter)
                    }
                } else if let listing {
                    browser(listing)
                }
            }
            .navigationTitle("Work in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Show hidden", isOn: $showHidden)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task {
            await session.loadPresets()
            await load(nil)
        }
    }

    private func browser(_ listing: DirectoryListing) -> some View {
        List {
            if !recents.isEmpty && listing.path == listing.home {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button {
                            pick(path)
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                // Two lines rather than one, to make room for
                                // the workspace. A recent is picked with one tap
                                // and never sees the bar at the bottom of this
                                // screen, so if the grouping is not said here it
                                // is not said at all.
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.system(size: 15, weight: .medium))
                                    Text(Format.path((path as NSString).deletingLastPathComponent, home: listing.home))
                                        .font(.code(10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: Metrics.tight)
                                // Only when there is a workspace. "Ungrouped" on
                                // every row of a machine that has no workspaces
                                // at all would be five copies of a fact about
                                // the machine, not about any of these folders.
                                if case .joins(_, let title) = session.placement(for: path) {
                                    Pill(title, color: Palette.accent, icon: "folder.fill")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }

            Section {
                ForEach(entries(listing)) { entry in
                    Button {
                        Task { await load(entry.path) }
                    } label: {
                        HStack(spacing: Metrics.gap) {
                            Image(systemName: "folder")
                                .foregroundStyle(Palette.accent)
                                .frame(width: 20)
                            Text(entry.name)
                                .font(.system(size: 15))
                                .foregroundStyle(entry.hidden ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                crumbs(listing)
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Metrics.tight) {
                presetRow
                placementNote(listing.path)
                Button("Start here") { pick(listing.path) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.tight)
            .background(.bar)
        }
    }

    /// One line above the start button saying where the conversation will land.
    ///
    /// Silent until the machine's workspace stream has spoken, rather than a
    /// claim the app cannot back up yet.
    @ViewBuilder
    private func placementNote(_ path: String) -> some View {
        switch session.placement(for: path) {
        case .joins(_, let title):
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                Text("Filed under \(title)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Only the branches that draw something pad the top, so a machine
            // that does not group keeps the bar it has always had.
            .padding(.top, Metrics.tight)
            .accessibilityElement(children: .combine)
        case .ungrouped:
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(claimProblem == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.bad))
                Text(claimProblem ?? "Not a workspace")
                    .font(.system(size: 13))
                    .foregroundStyle(claimProblem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.bad))
                    .lineLimit(2)
                Spacer(minLength: Metrics.tight)
                Button(claiming ? "Making…" : "Make one") { claim(path) }
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(claiming)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Metrics.tight)
        case .unknown:
            EmptyView()
        }
    }

    /// Claim the folder being browsed as a workspace.
    ///
    /// The sheet stays open on purpose. Making a workspace groups nothing by
    /// itself — the machine does not sweep up the conversations already in the
    /// folder — so the only thing that has changed is where the *next*
    /// conversation goes, and the way to see that is the line above this button
    /// flipping to "Filed under". Dismissing would hide the one piece of
    /// feedback there is.
    private func claim(_ path: String) {
        guard !claiming else { return }
        claiming = true
        claimProblem = nil
        Task {
            defer { claiming = false }
            // Reported here rather than on the list's banner, which is behind
            // this sheet and would deliver the message to nobody.
            claimProblem = await session.createWorkspace(path: path)
        }
    }

    /// What to show when the Mac cannot list folders for anyone but itself.
    ///
    /// dsh composes `directory-picker-auto`, which decides at boot whether the
    /// operator can see the host's screen — loopback bind, no SSH launch, a
    /// desktop OS — and on a Mac all three are true, so it mounts the *native*
    /// backend: an OS file dialog on that Mac. That is the right answer for the
    /// browser on the same desk and no answer at all for a phone somewhere
    /// else, and it is the **default**, so every Mac arrives here.
    ///
    /// An error and a dead end would therefore be the first thing most people
    /// see. Two things still work without the call: the folders this machine
    /// already has conversations in, which come from `session/list` and need
    /// nothing, and typing. Both are offered before the fix is mentioned,
    /// because most of the time the folder someone wants is one they have
    /// already used.
    private var cannotBrowse: some View {
        List {
            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { path in
                        Button {
                            pick(path)
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.system(size: 15, weight: .medium))
                                    Text(path)
                                        .font(.code(10))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                                Spacer(minLength: Metrics.tight)
                                if case .joins(_, let title) = session.placement(for: path) {
                                    Pill(title, color: Palette.accent, icon: "folder.fill")
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Folders you have used")
                }
            }

            Section {
                TextField("/Users/you/code/thing", text: $typed)
                    .font(.code(13))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                presetRow
                Button("Start here") { pick(typed.trimmingCharacters(in: .whitespaces)) }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Or type a path")
            } footer: {
                // No validation before sending. The app cannot check a path on
                // a machine that will not list its folders, and a guess that
                // said "no such folder" about a folder that exists would be
                // worse than letting the Mac answer.
                Text("Not checked until the conversation starts — this Mac will not list its folders, so there is nothing to check against.")
            }

            Section {
                // Both halves, deliberately. The picker is split in two: the
                // host plugin serves the listing API this app browses with,
                // and the client plugin registers the in-page browser the
                // desktop web UI picks with. The first version of this snippet
                // carried only the host half — every desktop that pasted it
                // got a "choose workspace" button that silently did nothing,
                // because the native Finder chooser was disabled and no
                // in-page picker had taken its slot.
                Text("""
                - id: directory-picker
                  disabled: true

                - insert:
                    - id: directory-picker-browse
                      name: '@deepseek-ai/dsh-host-directory-picker-browse'
                    - id: ui-directory-picker-browse
                      name: '@deepseek-ai/dsh-client-ui-directory-picker-browse'
                """)
                .font(.code(11))
                .textSelection(.enabled)
            } header: {
                Text("To browse folders from here")
            } footer: {
                Text("dsh decided at startup that whoever uses it can see this Mac's screen, so it opens a Finder window there instead of listing folders — which a phone cannot use. Add this to ~/.dsh/profiles/web/cordis.patch.yml. It reloads by itself; nothing needs restarting. The desktop web page then picks folders in the page rather than in Finder — reload that page once so it learns the new picker.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private func crumbs(_ listing: DirectoryListing) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(listing.crumbs) { crumb in
                    Button(crumb.name) {
                        Task { await load(crumb.path) }
                    }
                    .font(.system(size: 12, weight: .medium))
                    if crumb.id != listing.crumbs.last?.id {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .textCase(nil)
        }
    }

    private func entries(_ listing: DirectoryListing) -> [DirectoryEntry] {
        showHidden ? listing.entries : listing.entries.filter { !$0.hidden }
    }

    private func load(_ path: String?) async {
        loading = true
        problem = nil
        // Belongs to the folder that was on screen, not to this one.
        claimProblem = nil
        defer { loading = false }
        do {
            listing = try await session.harness.listDirectory(path: path)
            browsingOff = false
        } catch let failure as CallError where failure.code == "directory-picker-unavailable" {
            // Not a fault and not retryable: this machine has no browsable
            // picker mounted and will not grow one while the sheet is open.
            browsingOff = true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That folder couldn’t be read."
        }
    }

    private func pick(_ path: String?) {
        dismiss()
        onPick(path, preset)
    }

    /// The agent the conversation starts as, when the machine offers a choice.
    ///
    /// One row, menu on the right, silent otherwise: a machine that reports no
    /// presets — or only one — has nothing to choose, and dsh's own default is
    /// the right answer for almost every conversation. The description rides
    /// along in the menu because the names alone ("PTC 模式") assume knowledge
    /// the person picking may not have.
    @ViewBuilder
    private var presetRow: some View {
        if session.presets.count > 1 {
            HStack(spacing: 6) {
                Image(systemName: "person.text.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Agent")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: Metrics.tight)
                Menu {
                    Picker("Agent", selection: $preset) {
                        ForEach(session.presets) { option in
                            // The machine's default is expressed as nil so the
                            // create call can omit the field entirely, which is
                            // also what keeps an older dsh working.
                            VStack(alignment: .leading) {
                                Text(option.name)
                                if !option.detail.isEmpty {
                                    Text(option.detail)
                                }
                            }
                            .tag(option.isDefault ? String?.none : option.id)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(chosenPresetName)
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Palette.accent)
                }
            }
            .padding(.top, Metrics.tight)
        }
    }

    private var chosenPresetName: String {
        if let preset, let match = session.presets.first(where: { $0.id == preset }) {
            return match.name
        }
        return session.presets.first(where: \.isDefault)?.name ?? "Default"
    }
}
