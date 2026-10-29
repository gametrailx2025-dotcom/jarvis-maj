import SwiftUI

struct ChatPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Panel(title: "Conversation") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { MessageRow(message: $0).id($0.id) }
                        if model.isThinking {
                            Text("JARVIS réfléchit…").font(Theme.mono(12)).foregroundStyle(Theme.muted).id("thinking")
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let pending = model.pendingLabel {
                ConfirmBar(text: pending)
            }
            InputBar()
            QuickCommands()
        }
        .frame(maxHeight: .infinity)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.fromUser ? .trailing : .leading, spacing: 3) {
            Text((message.fromUser ? "Vous" : "JARVIS") + " · " + message.time)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
            Text(message.text)
                .font(.system(size: 16))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .background(
                    message.fromUser
                        ? AnyShapeStyle(LinearGradient(colors: [Theme.cyan.opacity(0.55), Theme.cyan.opacity(0.35)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.white.opacity(0.07))
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18,
                                                  bottomLeadingRadius: message.fromUser ? 18 : 5,
                                                  bottomTrailingRadius: message.fromUser ? 5 : 18,
                                                  topTrailingRadius: 18, style: .continuous))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 18,
                                           bottomLeadingRadius: message.fromUser ? 18 : 5,
                                           bottomTrailingRadius: message.fromUser ? 5 : 18,
                                           topTrailingRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(message.fromUser ? 0.15 : 0.08), lineWidth: 1)
                )
                .frame(maxWidth: 560, alignment: message.fromUser ? .trailing : .leading)
        }
        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }
}

struct ConfirmBar: View {
    @EnvironmentObject var model: AppModel
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield").font(.title2).foregroundStyle(Theme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Confirmation requise").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.amber)
                Text(text).font(.system(size: 14)).foregroundStyle(Theme.text)
            }
            Spacer()
            Button("Annuler") { Task { await model.answerConfirmation(false) } }
                .buttonStyle(HUDButtonStyle(filled: false))
            Button("Confirmer") { Task { await model.answerConfirmation(true) } }
                .buttonStyle(HUDButtonStyle(filled: true, tint: Theme.amber))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.amber.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.amber.opacity(0.6), lineWidth: 1))
    }
}

struct InputBar: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            let listening = model.speech.isRunning
            let tint = listening ? Theme.green : Theme.cyan
            // Le mot « Jarvis » suffit : le bouton micro n'apparaît que si l'écoute permanente est coupée.
            if !(model.wakeWordEnabled && model.speech.wakeMode) {
            Button { Task { await model.toggleListening() } } label: {
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tint.opacity(0.15)))
                    .overlay(Circle().stroke(tint, lineWidth: 1))
                    .shadow(color: listening ? tint : .clear, radius: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(listening ? "Arrêter l'écoute" : "Parler")
            }

            TextField("Parlez-moi ou écrivez…", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.cyan.opacity(focused ? 0.8 : 0.18), lineWidth: 1))
                .shadow(color: Theme.cyan.opacity(focused ? 0.25 : 0), radius: 10)
                .focused($focused)
                .onSubmit(submit)
                #if os(iOS)
                .submitLabel(.send)
                #endif

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(LinearGradient(colors: [Theme.cyanSoft, Theme.cyan],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Theme.cyan.opacity(0.45), radius: 8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
    }

    private func submit() {
        let t = text
        text = ""
        Task { await model.send(t) }
    }
}

struct QuickCommands: View {
    @EnvironmentObject var model: AppModel
    private let commands: [(String, String)] = [
        ("Briefing", "Debout"),
        ("Ma journée", "Que dois-je faire aujourd'hui ?"),
        ("État du PC", "Quel est l'état de mon ordinateur ?"),
        ("Météo", "Météo"),
        ("Mon jeu", "Lance mon jeu"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(commands, id: \.0) { item in
                    Button(item.0) { Task { await model.send(item.1) } }
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.text.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

struct HUDButtonStyle: ButtonStyle {
    var filled: Bool = true
    var tint: Color = Theme.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
            .background(Capsule().fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.10))))
            .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.5), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
