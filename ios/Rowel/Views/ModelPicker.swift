/// Switching a conversation's model.
///
/// Grouped by provider, because that is how the harness reports them and how
/// people think about them. Providers that failed to load are listed rather than
/// dropped: a missing model is otherwise indistinguishable from a model that was
/// never installed, and the fix is different.
///
/// Nothing is sent until Done. Tapping a model selects it in the sheet and shows
/// its thinking levels underneath; Done applies the model and level together,
/// Cancel (or swiping the sheet away) applies neither.

import SwiftUI

struct ModelPicker: View {
    let session: MachineSession
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelDraft?
    @State private var problem: String?
    /// Why Done did not go through; the sheet stays open so it can be retried.
    @State private var failure: String?
    @State private var applying = false

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    list(draft)
                } else if let problem {
                    Placeholder(icon: "exclamationmark.triangle", title: "Couldn’t list models", detail: problem)
                } else {
                    Placeholder(icon: "cpu", title: "Loading models…")
                }
            }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(applying)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if applying {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Done") { Task { await apply() } }
                            .fontWeight(.semibold)
                    }
                }
            }
            .interactiveDismissDisabled(applying)
        }
        .task { await load() }
    }

    private func list(_ draft: ModelDraft) -> some View {
        let catalog = draft.base
        return List {
            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups(catalog), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.options) { option in
                        Button {
                            self.draft?.choose(option)
                        } label: {
                            HStack(alignment: .top, spacing: Metrics.gap) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name)
                                        .font(.system(size: 15, weight: .medium))
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if draft.option?.id == option.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Palette.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)

                        // Under the model it belongs to, and only for the selected
                        // one. Showing every model's levels would triple the list
                        // to answer a question nobody asked about models they
                        // are not choosing.
                        if draft.option?.id == option.id {
                            let levels = catalog.efforts(for: option)
                            if !levels.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    // "" matches no segment: a level nobody named is
                                    // shown as unnamed, not as the first one.
                                    Picker("Thinking", selection: Binding(
                                        get: { draft.effort ?? "" },
                                        set: { self.draft?.choose(effort: $0) }
                                    )) {
                                        ForEach(levels) { level in
                                            Text(level.name).tag(level.id)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    if draft.effort == nil {
                                        Text("Model default. Pick a level to set one.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 4, leading: Metrics.gutter, bottom: 10, trailing: Metrics.gutter))
                            }
                        }
                    }
                }
            }
            if !catalog.failures.isEmpty {
                Section("Unavailable") {
                    ForEach(catalog.failures, id: \.self) { failure in
                        Text(failure)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct ProviderGroup {
        var provider: String
        var name: String
        var options: [ModelOption]
    }

    private func groups(_ catalog: ModelCatalog) -> [ProviderGroup] {
        var order: [String] = []
        var byProvider: [String: ProviderGroup] = [:]
        for option in catalog.options {
            if byProvider[option.provider] == nil {
                order.append(option.provider)
                byProvider[option.provider] = ProviderGroup(provider: option.provider, name: option.providerName, options: [])
            }
            byProvider[option.provider]?.options.append(option)
        }
        return order.compactMap { byProvider[$0] }
    }

    private func load() async {
        do {
            draft = ModelDraft(try await session.harness.models(sessionId: sessionId))
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "The Mac didn’t answer."
        }
    }

    /// Send the model and level chosen in the sheet, then close it.
    ///
    /// The draft already carries the new model's own default when no level was
    /// picked, so nil here really means "name none" and the machine keeps
    /// whatever the model defaults to.
    private func apply() async {
        guard let draft, draft.changed, let option = draft.option else {
            dismiss()
            return
        }
        applying = true
        defer { applying = false }
        // Through the session, not the harness. The header reads the
        // conversation, so a write that only touched this sheet's copy left the
        // two disagreeing until the next turn.
        if let refused = await session.selectModel(sessionId: sessionId, option: option, effort: draft.effort) {
            failure = refused
            return
        }
        dismiss()
    }
}
