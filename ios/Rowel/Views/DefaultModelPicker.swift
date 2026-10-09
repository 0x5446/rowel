/// What a new conversation starts on.
///
/// Separate from `ModelPicker`, which changes one live session, because the two
/// answer different questions and read from different places: this one asks the
/// machine for everything it can route to (`session/modelCatalog`), since the session it
/// is choosing for does not exist yet.
///
/// "Let the machine decide" is a real option and the default one. Someone with
/// a single provider configured never needs this screen, and an app that forced
/// a choice would be inventing a decision on their behalf.

import SwiftUI

struct DefaultModelPicker: View {
    let session: MachineSession

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: ModelCatalog?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Group {
                if let catalog {
                    list(catalog)
                } else if let problem {
                    Placeholder(icon: "exclamationmark.triangle", title: "Couldn’t list models", detail: problem)
                } else {
                    Placeholder(icon: "cpu", title: "Loading models…")
                }
            }
            .navigationTitle("New conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func list(_ catalog: ModelCatalog) -> some View {
        List {
            Section {
                row(
                    title: "Let \(session.machine.name) decide",
                    detail: "Whichever provider the machine picks first.",
                    selected: session.defaultModel == nil
                ) {
                    session.setDefaultModel(nil)
                    dismiss()
                }
            } footer: {
                Text("dsh has no setting for this, so a new conversation lands on whichever provider is configured first — which is the wrong one if that provider has no API key.")
            }

            ForEach(groups(catalog), id: \.provider) { group in
                Section(group.name) {
                    ForEach(group.options) { option in
                        row(
                            title: option.name,
                            detail: option.description,
                            selected: session.defaultModel == option
                        ) {
                            session.setDefaultModel(option)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func row(title: String, detail: String?, selected: Bool, choose: @escaping () -> Void) -> some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Metrics.gap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .foregroundStyle(.primary)
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
            catalog = try await session.harness.machineModels()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "The Mac didn’t answer."
        }
    }
}
