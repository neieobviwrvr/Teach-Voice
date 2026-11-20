import SwiftUI

/// Großer Player für den aktuellen Podcast: Fortschritt zum Ziehen,
/// 15 s zurück / 30 s vor, Tempo 1×–2×.
struct PodcastPlayerView: View {
    @EnvironmentObject private var player: PodcastPlayer
    @Environment(\.dismiss) private var dismiss

    /// Während der Finger auf dem Regler liegt: angezeigte Zielstelle. Erst
    /// beim Loslassen wird gesprungen.
    @State private var scrubPosition: TimeInterval?

    var body: some View {
        NavigationStack {
            Group {
                if let podcast = player.currentPodcast {
                    playerContent(podcast)
                } else {
                    ContentUnavailableView("Kein Podcast geladen", systemImage: "headphones")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func playerContent(_ podcast: Podcast) -> some View {
        let shownTime = scrubPosition ?? player.currentTime
        let remaining = max(0, player.duration - shownTime)

        return ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 110))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    .padding(.top, 24)

                Text(podcast.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                VStack(spacing: 6) {
                    Slider(
                        value: scrubBinding,
                        in: 0...max(player.duration, 1),
                        onEditingChanged: { editing in
                            if !editing, let target = scrubPosition {
                                player.seek(to: target)
                                scrubPosition = nil
                            }
                        }
                    )
                    HStack {
                        Text(PodcastProgress.clockLabel(shownTime))
                        Spacer()
                        Text("-" + PodcastProgress.clockLabel(remaining))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                HStack(spacing: 44) {
                    Button {
                        player.skip(by: -PodcastPlayer.skipBackSeconds)
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 34))
                    }
                    .accessibilityLabel("15 Sekunden zurück")

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 76))
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Abspielen")

                    Button {
                        player.skip(by: PodcastPlayer.skipForwardSeconds)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.system(size: 34))
                    }
                    .accessibilityLabel("30 Sekunden vor")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                rateMenu
            }
            .padding()
        }
    }

    private var scrubBinding: Binding<Double> {
        Binding(
            get: { scrubPosition ?? player.currentTime },
            set: { scrubPosition = $0 }
        )
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PodcastPlayer.rates, id: \.self) { rate in
                Button {
                    player.rate = rate
                } label: {
                    if rate == player.rate {
                        Label(PodcastProgress.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(PodcastProgress.rateLabel(rate))
                    }
                }
            }
        } label: {
            Label("Tempo \(PodcastProgress.rateLabel(player.rate))", systemImage: "speedometer")
        }
        .buttonStyle(.bordered)
    }
}
