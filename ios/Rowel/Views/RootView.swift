/// What the window shows.
///
/// Three states, in priority order: a broken identity, no machines yet, and the
/// normal case. Keeping the branch here means every other screen can assume it
/// has an identity and a machine, and none of them need an "if not paired" path.

import SwiftUI

public struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock

    public init() {}

    public var body: some View {
        Group {
            if let fatal = model.fatal {
                FatalView(message: fatal)
            } else if model.isNew {
                OnboardingView()
            } else {
                MachineView()
            }
        }
        .background(Palette.paper)
        .animation(.easeInOut(duration: 0.22), value: model.isNew)
        // Over everything, including the sheets — a settings sheet left open
        // when the app went away would otherwise be on top of the cover.
        // No animation: a cover that fades in is a cover that is transparent
        // during the frame the app switcher takes its picture.
        .overlay {
            if lock.isCovered {
                LockScreen()
                    .transition(.identity)
            }
        }
    }
}

/// The identity could not be read.
///
/// Retrying comes first, and reset is buried behind a confirmation, because the
/// most likely cause is temporary and the remedy is not: the key is stored
/// `afterFirstUnlockThisDeviceOnly`, so an app that wakes before the phone has
/// been unlocked once gets `errSecInteractionNotAllowed` and would otherwise be
/// telling the person to throw away every pairing they have to fix a condition
/// that clears by itself the moment they type their passcode.
struct FatalView: View {
    @Environment(AppModel.self) private var model
    let message: String

    @State private var confirmingReset = false
    @State private var retrying = false

    var body: some View {
        Placeholder(
            icon: "exclamationmark.triangle",
            title: "Rowel can’t start",
            detail: message
        ) {
            VStack(spacing: Metrics.tight) {
                Button(retrying ? "Trying…" : "Try again") {
                    retrying = true
                    // A moment of visible effort. Retrying a Keychain read takes
                    // microseconds, and a button that flickers reads as broken.
                    Task {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        model.retryIdentity()
                        retrying = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(retrying)

                Button("Reset Rowel", role: .destructive) { confirmingReset = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, Metrics.gutter * 2)
        }
        .alert("Reset Rowel?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) { model.resetEverything() }
        } message: {
            Text("This throws away this iPhone’s key and every pairing. You’ll have to scan a new code on each Mac. Nothing on your Macs changes.")
        }
    }
}

/// The connected machine: its conversations, and everything reachable from them.
struct MachineView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [String] = []
    @State private var showSettings = false
    @State private var showPicker = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let session = model.active {
                    SessionListView(session: session, path: $path)
                } else {
                    Placeholder(
                        icon: "desktopcomputer",
                        title: "No machine connected",
                        detail: "Pick one of your paired dsh to carry on."
                    ) {
                        Button("Choose a Mac") { showPicker = true }
                            .buttonStyle(SecondaryButtonStyle())
                            .padding(.horizontal, Metrics.gutter * 2)
                    }
                }
            }
            .navigationDestination(for: String.self) { sessionId in
                if let session = model.active {
                    ConversationView(session: session, sessionId: sessionId) { branched in
                        path.append(branched)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showPicker = true
                    } label: {
                        MachineChip(
                            name: model.active.map { model.label(for: $0.machine).name } ?? "Rowel",
                            suffix: model.active.flatMap { model.label(for: $0.machine).suffix },
                            status: model.active?.status ?? .idle
                        )
                    }
                    .accessibilityLabel("Switch Mac")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(Palette.paper, for: .navigationBar)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPicker) { MachinePicker() }
        .onChange(of: model.active?.machine.id) { _, _ in
            // Switching machines invalidates every session id on the stack.
            path = []
        }
    }
}

/// The title-bar control: which Mac, how it is reached, and whether it answers.
///
/// The route was already known — `TunnelStatus.online` has always carried it —
/// and already live, since an upgrade to Wi-Fi replaces the status and SwiftUI
/// redraws from it. It was simply buried in Settings, which is the wrong place
/// for a fact that changes by itself while you watch. Two paths with different
/// costs and different privacy stories should not look identical on the screen
/// you spend all your time on.
///
/// An icon rather than a word, because this sits in a toolbar next to a machine
/// name that can be long: an antenna for a local hop, a cloud for the relay.
/// The accessibility label spells it out, and Settings still gives the sentence.
struct MachineChip: View {
    let name: String
    /// Collision disambiguator; see `MachineLabel`. Its own element on
    /// purpose: the name truncates from the end, and a suffix concatenated
    /// into it would be the first thing cut — on exactly the screen where
    /// two same-named machines most need telling apart.
    let suffix: String?
    let status: TunnelStatus

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if let suffix {
                Text(suffix)
                    .font(.code(11))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .layoutPriority(1)
            }
            if let carrier {
                Image(systemName: carrier == .lan ? "wifi" : "cloud")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(carrier == .lan ? AnyShapeStyle(Palette.good) : AnyShapeStyle(.secondary))
                    .accessibilityLabel(carrier == .lan ? "Direct over Wi-Fi" : "Through the relay")
                    // Route changes mid-session, on purpose. Sliding one icon
                    // out and the other in is what makes that legible as a
                    // change rather than a redraw someone half-noticed.
                    .transition(.opacity.combined(with: .scale))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .foregroundStyle(.primary)
        .animation(.easeInOut(duration: 0.25), value: carrier)
    }

    private var carrier: Carrier? {
        if case .online(let carrier, _, _) = status { return carrier }
        return nil
    }
}

/// Connection state as one dot. The colour carries the meaning; the status line
/// under the header carries the words, so this stays silent when all is well.
struct StatusDot: View {
    let status: TunnelStatus
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .opacity(connecting && pulsing ? 0.3 : 1)
            .animation(connecting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulsing)
            .onAppear { pulsing = true }
    }

    private var connecting: Bool {
        if case .connecting = status { return true }
        return false
    }

    private var colour: Color {
        switch status {
        case .online(_, _, let harnessUp): return harnessUp ? Palette.good : Palette.warn
        // The dot pulses while connecting, which already reads as activity.
        // Colouring it amber on top of that turns every launch into a warning.
        case .connecting: return .secondary
        case .waiting: return Palette.warn
        case .refused: return Palette.bad
        case .idle: return .secondary
        }
    }
}

/// One line of plain language about the connection, shown only when something is
/// not normal. A connected app says nothing, because "Connected" is noise.
struct StatusLine: View {
    @Environment(AppModel.self) private var model
    let session: MachineSession

    var body: some View {
        if let message {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if retryable {
                    Button("Retry") { session.poke() }
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Metrics.gutter)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.11))
        }
    }

    /// Collision-aware name for prose; two same-named Macs must not produce
    /// two identical banners.
    private var machineLabel: String {
        model.label(for: session.machine).prose
    }

    private var message: String? {
        switch session.status {
        case .idle:
            return nil
        case .connecting:
            // Grey words, not silence and not a warning. The first version of
            // this banner was amber, which painted every launch as a problem;
            // the second was silent on a cold start, leaving the skeleton to
            // speak alone — and a person watching it asked, reasonably, what
            // the app was actually doing. Saying so in the calm colour is the
            // middle both versions missed.
            return session.sessions.isEmpty
                ? "Connecting to \(machineLabel)…"
                : "Reconnecting to \(machineLabel)…"
        case .waiting(let detail, let retryIn, _):
            let seconds = max(1, Int(retryIn.rounded()))
            return "\(detail) Trying again in \(seconds)s."
        case .refused(let reason):
            switch reason {
            case .unpaired:
                return "\(machineLabel) doesn’t recognise this iPhone. Run `bridle pair` on the Mac and scan the new code."
            case .version(let appIsOlder):
                // Naming the end that is behind is the whole reason the machine
                // sends its supported versions. "Update the older one" leaves
                // the person to guess, and they will guess wrong half the time.
                return appIsOlder
                    ? "Rowel is older than the Bridle on \(machineLabel). Update Rowel."
                    : "The Bridle on \(machineLabel) is older than Rowel. Run `npm update` there, or update the dsh plugin."
            case .machineError(let detail):
                return detail
            }
        case .online:
            if let detail = session.harnessDetail { return detail }
            // Briefly, after a switch. Above "Catching up…" because a route
            // change is the rarer and more surprising of the two.
            if let change = session.routeChange { return change }
            // The stretch after a reconnect where the list on screen is from
            // before. Refreshing is invisible otherwise — the rows sit there
            // looking current while being anything but — and this window is
            // most of what "the app takes forever to open" felt like.
            if session.listing && !session.sessions.isEmpty { return "Catching up…" }
            return nil
        }
    }

    private var icon: String {
        switch session.status {
        case .refused: return "xmark.octagon"
        case .online: return "bolt.horizontal.circle"
        default: return "antenna.radiowaves.left.and.right"
        }
    }

    private var tint: Color {
        switch session.status {
        case .refused: return Palette.bad
        // Catching up is routine; only a harness problem earns amber.
        case .online where session.harnessDetail == nil: return .secondary
        // Amber is a claim that something is wrong, and reconnecting is not:
        // it is the normal end of every phone's every network. Grey says "hold
        // on" — which is what is happening — and keeps amber meaning something,
        // so that `waiting`, which really is a failure with a reason attached,
        // is not competing with the routine for the same colour.
        case .connecting: return .secondary
        default: return Palette.warn
        }
    }

    private var retryable: Bool {
        switch session.status {
        case .waiting: return true
        case .online: return false
        default: return false
        }
    }
}

/// Switch between paired dsh, or add another.
///
/// The unit of pairing is a dsh (through the Bridle fronting it), not the
/// computer: one Mac can run two, and each row here is one of them. The row
/// still wears the machine name, because people recognise machines — the
/// port lives in the detail page.
struct MachinePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.machines) { machine in
                        Button {
                            model.connect(to: machine.id)
                            dismiss()
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                Image(systemName: "desktopcomputer")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.label(for: machine).name).font(.system(size: 16, weight: .medium))
                                        if let suffix = model.label(for: machine).suffix {
                                            Text(suffix).font(.code(11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(machine.id)
                                        .font(.code(11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if model.active?.machine.id == machine.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Pair another dsh", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("Your dsh")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $adding) {
            PairingFlow { dismiss() }
        }
    }
}
