/// Settings, and the security screen that lives inside them.
///
/// Most of this is one-time: the device name, and forgetting a Mac. The part
/// worth reading is the connection section, which is the only place someone can
/// check what the app is actually doing — direct or relayed, and against which
/// key. Putting that behind a "learn more" link would be a way of not saying it.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingReset = false
    @State private var choosingDefaultModel = false
    @State private var unpairing: PairedMachine?
    @State private var showingDiagnostics = false
    @State private var showingPlugins = false
    /// Shown while the machine has not confirmed, and rolled back if it refuses.
    @State private var pendingAccess: String?
    @State private var accessError: String?

    var body: some View {
        @Bindable var model = model
        @Bindable var lock = lock

        NavigationStack {
            List {
                if let session = model.active {
                    connection(session)

                    Section {
                        Button {
                            choosingDefaultModel = true
                        } label: {
                            LabeledContent("New conversations use") {
                                Text(session.defaultModel?.name ?? "Machine default")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        // Beside the default model because it is the same kind
                        // of thing: this sets what a conversation that does not
                        // exist yet will start as. Changing one that is already
                        // running is a different act with a different dsh call
                        // (`/permission` on that session), and it lives where
                        // that conversation is — Session ▸ Access.
                        if let permissions = session.accessDefault {
                            Picker("New conversations can", selection: Binding(
                                get: { pendingAccess ?? permissions.current },
                                set: { chosen in
                                    pendingAccess = chosen
                                    Task {
                                        if let failure = await session.setPermission(chosen) {
                                            pendingAccess = nil
                                            accessError = failure
                                        }
                                    }
                                }
                            )) {
                                ForEach(permissions.options) { option in
                                    Text(PermissionChoice.label(for: option.value)).tag(option.value)
                                }
                            }
                        }
                        if let accessError {
                            Text(accessError)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Palette.warn)
                        }
                    } header: {
                        Text("New conversations")
                    } footer: {
                        Text("dsh routes a new conversation to whichever provider is configured first, so naming one here means it starts on the model you meant. Access is the mode the next conversation begins in, on this Mac, for every client. A conversation that is already running keeps whatever it has — that one is changed from its own Session ▸ Access.")
                    }
                }

                Section("This iPhone") {
                    LabeledContent("Name") {
                        TextField("iPhone", text: $model.deviceName)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                    }
                    Row(label: "Key fingerprint", value: model.deviceFingerprint, mono: true)
                        .textCase(nil)
                }

                Section {
                    Toggle("Lock Rowel", isOn: $lock.isEnabled)
                        .disabled(!lock.canAuthenticate)
                    if lock.isEnabled {
                        Picker("Lock when away", selection: $lock.delay) {
                            ForEach(LockDelay.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    Text(lock.canAuthenticate
                        ? "A paired iPhone can approve commands on your Mac, so an unlocked one in the wrong hands is a shell. Locking bounds how long that lasts — but it is not a substitute for running `bridle revoke` on the Mac if you lose this phone."
                        : "Set a device passcode in iOS Settings to use this. Without one there is nothing for Rowel to check.")
                }

                Section {
                    ForEach(model.machines) { machine in
                        // Into a detail page, not straight into a destructive
                        // confirm. Tapping a machine used to *be* the forget
                        // flow — the most reversible-looking gesture on the
                        // screen wired to the least reversible act — while
                        // rename existed in the model with no way to reach it.
                        NavigationLink {
                            MachineDetailView(machineId: machine.id)
                        } label: {
                            HStack(spacing: Metrics.gap) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(model.label(for: machine).name)
                                            .font(.system(size: 15, weight: .medium))
                                        if let suffix = model.label(for: machine).suffix {
                                            Text(suffix).font(.code(11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(machine.fingerprint)
                                        .font(.code(11))
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: Metrics.tight)
                                if machine.id == model.active?.machine.id {
                                    Text("Connected")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        // Forget stays reachable by swipe for people who
                        // expect it, and lives in the detail page for people
                        // who do not.
                        .swipeActions {
                            Button(role: .destructive) {
                                unpairing = machine
                            } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("Paired dsh")
                } footer: {
                    Text("Each pairing is one dsh on one machine. Tap to rename it or see details. To stop that machine trusting this iPhone, run `bridle revoke` there — this end cannot do it for you.")
                }

                Section {
                    Link(destination: Links.help) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    Link(destination: Links.privacy) {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    Row(label: "Version", value: model.clientVersion)
                }

                Section {
                    Button("Start over as a new device", role: .destructive) { confirmingReset = true }
                } footer: {
                    Text("Throws away this iPhone’s key, so every Mac stops recognising it and you pair again from scratch. Only useful if the key itself is the problem — to remove one Mac, tap it above.")
                }
            }
            .task { await model.active?.refreshAccessDefault() }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $choosingDefaultModel) {
                if let session = model.active {
                    DefaultModelPicker(session: session)
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                if let session = model.active {
                    DiagnosticsView(session: session)
                }
            }
            .sheet(isPresented: $showingPlugins) {
                if let session = model.active {
                    PluginsView(session: session)
                }
            }
            .confirmationDialog("Start over as a new device?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Start over", role: .destructive) {
                    // Irreversible from here, and it takes every pairing with
                    // it. Whoever is holding the phone has to be its owner.
                    Task {
                        guard await lock.confirm("Throw away this iPhone’s key and unpair every Mac.") else { return }
                        model.resetEverything()
                        dismiss()
                    }
                }
            } message: {
                Text("This iPhone gets a new key. Every Mac will treat it as one it has never seen, and each will still list the old one until you run `bridle revoke` there.")
            }
            .confirmationDialog(
                unpairing.map { "Forget \($0.name)?" } ?? "",
                isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
                titleVisibility: .visible
            ) {
                Button("Forget this Mac", role: .destructive) {
                    let target = unpairing
                    unpairing = nil
                    Task {
                        guard let target,
                              await lock.confirm("Forget \(target.name) on this iPhone.") else { return }
                        model.unpair(target.id)
                    }
                }
            } message: {
                Text("It disappears from this iPhone. That Mac still trusts this iPhone until you run `bridle revoke` on it.")
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private func connection(_ session: MachineSession) -> some View {
        Section {
            Row(label: "Machine", value: session.machine.name)
            Row(label: "Route", value: route(session))
            if let info = session.machineInfo {
                Row(label: "dsh", value: info.version)
                Row(label: "Folder", value: Format.path(info.cwd, home: info.cwd), mono: true)
            }
            // The one check a person can perform, so it says how.
            //
            // A six-digit confirmation number used to sit further down this
            // screen in large type, with a line telling people to compare it
            // against what their Mac prints. The Mac has never printed it:
            // `confirmationNumber` is called in this app and nowhere else. A
            // number nobody can check is worse than no number, because whoever
            // cannot find its twin concludes they are looking in the wrong
            // place and pairs anyway.
            //
            // This one exists on both ends. A relay that swapped the machine's
            // key in a short-code bundle cannot make the two agree, because it
            // does not hold the machine's private key.
            VStack(alignment: .leading, spacing: 4) {
                Row(label: "Its fingerprint", value: session.machine.fingerprint, mono: true)
                Text("Your Mac prints this on the `identity` line of `bridle pair` and `bridle status`. If it differs, forget this Mac and pair again.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showingDiagnostics = true
            } label: {
                // Named plainly after someone went looking for it and could
                // not find it. In a list of nouns — Machine, Route, dsh,
                // Folder — a prose phrase reads as a sentence to skip rather
                // than a row to tap, however much better it sounds alone.
                LabeledContent("Connection log") {
                    Text(session.notes.isEmpty ? "—" : "\(session.notes.count) lines")
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            Button {
                showingPlugins = true
            } label: {
                LabeledContent("Plugins") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("Connection")
        } footer: {
            Text(session.carrier == .lan
                ? "Direct over your local network. Nothing leaves your Wi-Fi."
                : "Through the relay, which forwards encrypted bytes it can’t read.")
        }
    }

    private func route(_ session: MachineSession) -> String {
        switch session.status {
        case .online(let carrier, _, let harnessUp):
            let path = carrier == .lan ? "Direct (Wi-Fi)" : "Relay"
            return harnessUp ? path : "\(path), dsh down"
        case .connecting: return "Connecting"
        case .waiting: return "Retrying"
        case .refused: return "Refused"
        case .idle: return "Not connected"
        }
    }
}

/// A label and a value, the way every settings row in the app looks.
private struct Row: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: Metrics.gap)
            Text(value)
                .font(mono ? .code(12) : .system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}


/// One paired machine, in full.
///
/// Looked up by id on every render rather than captured: renaming has to be
/// visible immediately, and a machine forgotten elsewhere has to make this
/// page dismiss itself instead of editing a ghost.
struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machineId: String

    @State private var name = ""
    @State private var confirmingForget = false

    private var machine: PairedMachine? {
        model.machines.first { $0.id == machineId }
    }

    var body: some View {
        List {
            if let machine {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit { commitName() }
                    if let reported = machine.reportedName, reported != machine.name {
                        Button("Use the Mac’s name (\(reported))") {
                            model.rename(machine: machineId, to: reported)
                            name = reported
                        }
                        .font(.system(size: 14))
                    }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Only on this iPhone. Re-pairing keeps it; the Mac’s own name stays what it was.")
                }

                Section {
                    Row(label: "Fingerprint", value: machine.fingerprint)
                    Row(label: "Device id", value: machine.id)
                    // Honest about vintage: the port is a fact about the
                    // connection, so it is only claimed while one exists.
                    // "Connect to see" beats a cached number that may be a
                    // different instance by now.
                    if machine.id == model.active?.machine.id,
                       model.active?.isOnline == true,
                       let port = model.active?.harnessInfo?.port {
                        Row(label: "Harness", value: ":" + port)
                    } else {
                        Row(label: "Harness", value: "connect to see")
                    }
                } header: {
                    Text("Identity")
                }

                Section {
                    Button("Forget This Mac", role: .destructive) {
                        confirmingForget = true
                    }
                    .frame(maxWidth: .infinity)
                } footer: {
                    Text("One-sided: the Mac still trusts this iPhone until you run `bridle revoke` there.")
                }
            }
        }
        .navigationTitle(machine.map { model.label(for: $0).prose } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = machine?.name ?? "" }
        .onDisappear { commitName() }
        .confirmationDialog(
            "Forget \(machine?.name ?? "this Mac")?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                // Leave first, then unpair: unpair switches the active
                // connection, and this page must not stay open over a record
                // that no longer exists.
                dismiss()
                let id = machineId
                Task { @MainActor in
                    model.unpair(id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let machine, !trimmed.isEmpty, trimmed != machine.name else { return }
        model.rename(machine: machineId, to: trimmed)
    }
}
