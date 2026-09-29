/// First run, and the only screen most people will ever read.
///
/// The whole flow is two things: run one command on the Mac, then point the
/// camera at what it prints. Everything here exists to make that feel like two
/// things rather than a setup procedure — no accounts, no server address, no
/// port numbers, no certificate warnings.

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OnboardingView: View {
    @State private var pairing = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Metrics.gap) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 46, weight: .thin))
                    .foregroundStyle(Palette.accent)
                Text("Rowel")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Your coding agent, in your pocket.")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .leading, spacing: Metrics.gap) {
                Promise(icon: "lock.shield", text: "End-to-end encrypted. The relay forwards bytes it can’t read.")
                Promise(icon: "person.crop.circle.badge.xmark", text: "No account. Nothing to sign up for.")
                Promise(icon: "wifi", text: "On the same Wi-Fi, it connects straight to your Mac.")
            }
            .padding(.horizontal, Metrics.gutter * 1.5)
            Spacer()
            VStack(spacing: Metrics.tight) {
                Button("Connect a Mac") { pairing = true }
                    .buttonStyle(PrimaryButtonStyle())
                Text("Takes about a minute.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.gutter)
        }
        .sheet(isPresented: $pairing) { PairingFlow() }
    }
}

private struct Promise: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.gap) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pairing

/// The pairing sheet: install, then scan.
///
/// Two steps rather than one screen because the install has to finish before the
/// code exists, and a person who already installed it should be able to skip
/// straight past. The scanner is the default second step; typing a code is the
/// fallback for a Mac that is not in the room.
struct PairingFlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onPaired: (() -> Void)?

    @State private var step = Step.install
    @State private var typing = false
    @State private var code = ""
    @State private var claiming = false
    @State private var problem: String?

    enum Step { case install, scan }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .install: install
                case .scan: scan
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Step one

    private var install: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("On your Mac")
                    .font(.system(size: 26, weight: .bold))
                Text("Open Terminal and paste this. It installs Bridle, the small helper that connects Rowel to the agent already running on that machine.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                CommandBlock(command: Links.installCommand)

                Text("Then start pairing:")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                CommandBlock(command: Links.pairCommand)

                Text("No `bridle` command? Run the install line above — it’s what provides the command, and it’s safe even when Bridle is already running with dsh.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Label {
                    Text("Bridle prints a QR code. Leave it on screen.")
                        .font(.system(size: 14))
                } icon: {
                    Image(systemName: "qrcode")
                }
                .foregroundStyle(.secondary)
                .padding(.top, 4)

                Spacer(minLength: Metrics.gutter)

                Button("I’ve run it — scan the code") { step = .scan }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Enter a code instead") { typing = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Metrics.gutter)
        }
        .sheet(isPresented: $typing) { codeSheet }
    }

    // MARK: Step two

    private var scan: some View {
        ScannerView { payload in
            guard let bundle = try? Pairing.decodeLink(payload) else {
                problem = "That isn’t a Rowel pairing code."
                return false
            }
            model.pair(with: bundle)
            finish()
            return true
        } onCancel: {
            step = .install
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: Metrics.tight) {
                if let problem {
                    Text(problem)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Metrics.gap)
                        .padding(.vertical, Metrics.tight)
                        .background(Palette.bad, in: Capsule())
                }
                Button("Enter a code instead") { typing = true }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.45), in: Capsule())
            }
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $typing) { codeSheet }
        .ignoresSafeArea(edges: .bottom)
    }

    // MARK: Typed code

    private var codeSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Metrics.gutter) {
                Text("Type the code from “bridle pair --code” on your Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("ABCD-EFGH", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Metrics.gap)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))

                if let problem {
                    Text(problem)
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.bad)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Your Mac then asks whether to accept this iPhone and shows a key. Accept only if it is this one: \(model.deviceFingerprint)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                Button {
                    Task { await claim() }
                } label: {
                    if claiming { ProgressView().tint(.white) } else { Text("Connect") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(claiming || code.count < 8)
            }
            .padding(Metrics.gutter)
            .navigationTitle("Pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { typing = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func claim() async {
        claiming = true
        problem = nil
        defer { claiming = false }
        do {
            try await model.pair(shortCode: code)
            typing = false
            finish()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That code didn’t work."
        }
    }

    private func finish() {
        dismiss()
        onPaired?()
    }
}

/// A shell command with a copy button. Copying is the whole point: nobody should
/// retype a curl line from a phone screen.
struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.tight) {
            Text(command)
                .font(.code(13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                #if canImport(UIKit)
                UIPasteboard.general.string = command
                #endif
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(copied ? Palette.good : Palette.accent)
            }
            .accessibilityLabel("Copy command")
        }
        .padding(Metrics.gap)
        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
    }
}
