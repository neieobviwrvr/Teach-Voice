import SwiftUI

struct StudyView: View {
    let subfolder: Subfolder
    let cards: [Flashcard]

    @StateObject private var speech = SpeechService()
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var transcriber = WhisperTranscriber()

    @State private var index = 0
    @State private var transcribedAnswer: String?
    @State private var isTranscribing = false

    private var currentCard: Flashcard? {
        cards.indices.contains(index) ? cards[index] : nil
    }

    var body: some View {
        VStack(spacing: 24) {
            if let card = currentCard {
                Text("Karte \(index + 1) von \(cards.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    Text(card.question)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Button {
                        speech.speak(card.question)
                    } label: {
                        Label(speech.isSpeaking ? "Spielt ab…" : "Frage nochmal vorlesen", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                whisperStatusView

                recordButton

                if let transcribedAnswer {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deine Antwort:").font(.caption).foregroundStyle(.secondary)
                        Text(transcribedAnswer)
                        Divider()
                        Text("Richtige Antwort:").font(.caption).foregroundStyle(.secondary)
                        Text(card.answer)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }

                Spacer()

                Button("Nächste Karte") {
                    nextCard()
                }
                .buttonStyle(.borderedProminent)
                .disabled(index >= cards.count - 1 && transcribedAnswer == nil)
            } else {
                ContentUnavailableView("Fertig!", systemImage: "checkmark.seal.fill", description: Text("Du hast alle Karten in diesem Unterordner durchgesprochen."))
            }
        }
        .padding()
        .navigationTitle("Lernmodus")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await transcriber.prepareIfNeeded()
            if let card = currentCard { speech.speak(card.question) }
        }
        .onDisappear { speech.stop() }
    }

    @ViewBuilder
    private var whisperStatusView: some View {
        switch transcriber.state {
        case .downloading:
            Label("Whisper-base wird einmalig lokal geladen…", systemImage: "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var recordButton: some View {
        Button {
            Task { await toggleRecording() }
        } label: {
            Label(
                recorder.isRecording ? "Aufnahme beenden" : "Antwort sprechen",
                systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .font(.title3)
        }
        .buttonStyle(.borderedProminent)
        .tint(recorder.isRecording ? .red : .accentColor)
        .disabled(isTranscribing)
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            guard let url = recorder.stopRecording() else { return }
            isTranscribing = true
            transcribedAnswer = await transcriber.transcribe(audioURL: url)
            isTranscribing = false
        } else {
            transcribedAnswer = nil
            await recorder.startRecording()
        }
    }

    private func nextCard() {
        transcribedAnswer = nil
        index += 1
        if let card = currentCard {
            speech.speak(card.question)
        }
    }
}
