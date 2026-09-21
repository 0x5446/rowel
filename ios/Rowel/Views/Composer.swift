/// Where messages get written.
///
/// One rule shapes the whole thing: sending must never be blocked. If a turn is
/// running, the message steers it; if the machine is offline, the field still
/// accepts text and says why it hasn't gone yet. A composer that greys itself out
/// is a composer that loses what someone typed.

import PhotosUI
import SwiftUI

struct Composer: View {
    let running: Bool
    let planning: Bool
    let enabled: Bool
    /// What this session offers after a slash: its skills and the commands the
    /// machine will run for it. Empty is fine and common — a machine with
    /// nothing installed, or a list that has not arrived yet.
    var commands: [SlashCommand] = []
    let onSend: (String, [PromptImage]) -> Void
    let onStop: () -> Void

    @State private var text = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [PromptImage] = []
    @State private var loadingImages = false
    @State private var focused = false
    /// Why the draft was not sent, when the reason is about the draft itself.
    @State private var refusal: String?

    var body: some View {
        VStack(spacing: Metrics.tight) {
            // Above the field, so the list grows away from the thumb and the
            // field it filters stays visible under it.
            if let prefix = commandPrefix(in: text), !commands.isEmpty {
                CommandPicker(commands: commands, filter: prefix) { command in
                    // A trailing space: every one of these takes an argument or
                    // is happy without one, and either way the next keystroke
                    // should not extend the name.
                    text = "/\(command.name) "
                }
                .padding(.horizontal, -Metrics.gutter)
            }
            if let refusal {
                Text(refusal)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("composer.refusal")
            }
            if !images.isEmpty || loadingImages {
                attachments
            }
            HStack(alignment: .bottom, spacing: Metrics.tight) {
                PhotosPicker(selection: $picked, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 34)
                }
                .accessibilityLabel("Attach a photo")

                // Not `TextField(axis: .vertical)`: that measures the whole
                // string on every keystroke and froze the app on a pasted log.
                // See GrowingField for the numbers.
                // The placeholder is deliberately not stable — it states why
                // sending is unusual right now — so tests and VoiceOver get the
                // fixed name and label instead.
                GrowingField(
                    text: $text, focused: $focused, maxLines: 6,
                    identifier: "composer.field", label: "Message"
                )
                    .overlay(alignment: .topLeading) {
                        // Drawn here rather than inside the text view: a label
                        // constrained inside a UITextView is a subview of a
                        // scroll view, and resolving it costs the whole-document
                        // layout this view exists to avoid.
                        if text.isEmpty {
                            Text(prompt)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, Metrics.gap)
                    .padding(.vertical, 8)
                    .background(Palette.well, in: RoundedRectangle(cornerRadius: 19, style: .continuous))

                action
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.tight)
        .padding(.bottom, Metrics.tight)
        .background(.bar)
        .task(id: picked.count) { await loadPicked() }
        // The line is about a draft that no longer exists once the person touches
        // the field again, and a warning that outlives its cause is noise.
        .onChange(of: text) { refusal = nil }
    }

    private var prompt: String {
        if !enabled { return "Message — sends when reconnected" }
        if planning { return "Reply — it’s planning first" }
        if running { return "Steer it…" }
        return "Message"
    }

    @ViewBuilder
    private var action: some View {
        if running && text.isEmpty && images.isEmpty {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Palette.bad, in: Circle())
            }
            .accessibilityLabel("Stop")
        } else {
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(sendable ? Palette.accent : Color.secondary.opacity(0.4), in: Circle())
            }
            .disabled(!sendable)
            .accessibilityLabel("Send")
        }
    }

    private var sendable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Metrics.tight) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        AttachmentThumb(image: ImageAttachment(id: "\(index)", mediaType: image.mediaType, base64: image.base64))
                        Button {
                            images.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .padding(2)
                    }
                }
                if loadingImages {
                    ProgressView()
                        .frame(width: 56, height: 56)
                        .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 60)
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !images.isEmpty else { return }
        // A command takes no attachments, and nothing here can un-attach one
        // after the fact. So the draft stays put and the line says why: refusing
        // is the only option that neither drops the photo nor hands the command
        // to the model as words. dsh's own composer refuses the same way, with
        // the same reason.
        if let why = draftRefusal(text: body, hasImages: !images.isEmpty, among: commands) {
            refusal = why
            return
        }
        refusal = nil
        onSend(body, images)
        text = ""
        images = []
        picked = []
        // Give the screen back. The keyboard is half a phone, and what someone
        // wants immediately after sending is to watch the answer arrive — not
        // to type the next message into a slot four lines tall.
        focused = false
    }

    /// Downscale before encoding. A 12-megapixel photo is several megabytes of
    /// base64 through a phone uplink for an image the model reads at a fraction of
    /// that size, and the wait is the person's.
    private func loadPicked() async {
        guard !picked.isEmpty else { return }
        loadingImages = true
        defer { loadingImages = false }
        var loaded: [PromptImage] = []
        for item in picked {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            guard let shrunk = Composer.shrink(data) else { continue }
            loaded.append(PromptImage(mediaType: "image/jpeg", base64: shrunk.base64EncodedString(), name: nil))
        }
        images.append(contentsOf: loaded)
        picked = []
    }

    static func shrink(_ data: Data, longestSide: CGFloat = 1568) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let side = max(image.size.width, image.size.height)
        guard side > longestSide else { return image.jpegData(compressionQuality: 0.8) }
        let scale = longestSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.8)
        #else
        return data
        #endif
    }
}

/// Messages sent but not yet claimed by the agent. Shown above the composer so
/// someone can see what is still coming and take one back.
struct QueueStrip: View {
    let queue: [QueuedMessage]
    let onRemove: (QueuedMessage) -> Void
    /// Cut this one into the turn already running.
    var onPromote: ((QueuedMessage) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            ForEach(queue) { item in
                HStack(spacing: Metrics.tight) {
                    Image(systemName: item.placement == "steering" ? "arrow.turn.up.right" : "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(item.text)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let onPromote, item.placement != "steering" {
                        // dsh's own client offers this and the app did not: a
                        // queued message waits for the turn to finish, and
                        // sometimes what you have just typed is the reason the
                        // turn should stop. Sending is queueing now, so this is
                        // the only way to say the other thing.
                        Button {
                            onPromote(item)
                        } label: {
                            Image(systemName: "arrow.up.circle")
                                .font(.system(size: 15))
                                .foregroundStyle(Palette.accent)
                        }
                        .accessibilityLabel("Send this now")
                    }
                    Button {
                        onRemove(item)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, Metrics.gap)
                .padding(.vertical, 7)
                .background(Palette.well, in: RoundedRectangle(cornerRadius: Metrics.smallRadius, style: .continuous))
            }
        }
        .padding(.horizontal, Metrics.gutter)
    }
}
