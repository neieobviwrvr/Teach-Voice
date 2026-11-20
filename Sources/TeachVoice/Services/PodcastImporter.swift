import AVFoundation

enum PodcastImportError: LocalizedError {
    case unreadable
    case noAudio

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Die Datei lässt sich nicht als Audio lesen."
        case .noAudio: return "In der Datei ist keine Tonspur."
        }
    }
}

/// Importiert eine Audiodatei (z.B. NotebookLM-.m4a aus der Dateien-App) in
/// den Podcast-Ordner. Hat die Datei eine hohe Datenrate, wird sie auf
/// Sprachqualität heruntergerechnet (`PodcastImportRule`); klappt das nicht
/// oder wird die Datei dadurch nicht kleiner, bleibt das Original -- ein
/// Import scheitert nie am Komprimieren.
enum PodcastImporter {
    static func importFile(from source: URL, into directory: URL) async throws -> Podcast {
        let id = UUID()
        let originalName = source.lastPathComponent
        let ext = PodcastImportRule.fileExtension(forFileName: originalName)

        // Erst eine eigene Kopie ziehen: Dateien aus iCloud Drive oder
        // anderen Apps sind nur während des Zugriffs lesbar (und werden bei
        // Bedarf erst heruntergeladen), AVFoundation liest aber asynchron.
        let copyURL = directory.appendingPathComponent("\(id.uuidString).\(ext)")
        try FileImport.copyPickedFile(from: source, to: copyURL)

        do {
            let asset = AVURLAsset(url: copyURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw PodcastImportError.unreadable }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw PodcastImportError.noAudio }

            var fileURL = copyURL
            var compressed = false
            let originalSize = fileSize(copyURL)
            if PodcastImportRule.shouldCompress(byteSize: originalSize, duration: duration) {
                let target = directory.appendingPathComponent("\(id.uuidString)-aac.m4a")
                do {
                    try await compress(asset: asset, track: track, to: target)
                    if fileSize(target) > 0, fileSize(target) < originalSize {
                        try? FileManager.default.removeItem(at: copyURL)
                        fileURL = target
                        compressed = true
                    } else {
                        try? FileManager.default.removeItem(at: target)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: target)
                }
            }

            return Podcast(
                id: id,
                title: PodcastImportRule.defaultTitle(forFileName: originalName),
                fileName: fileURL.lastPathComponent,
                duration: duration,
                byteSize: fileSize(fileURL),
                importedAt: Date(),
                wasCompressed: compressed,
                position: 0,
                finishedAt: nil,
                folderId: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: copyURL)
            throw error
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        FileImport.fileSize(url)
    }

    /// Rechnet die Tonspur auf AAC mono 64 kbit/s um.
    private static func compress(asset: AVAsset, track: AVAssetTrack, to target: URL) async throws {
        try? FileManager.default.removeItem(at: target)

        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: PodcastImportRule.targetSampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw PodcastImportError.unreadable }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: target, fileType: .m4a)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: PodcastImportRule.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: PodcastImportRule.targetBitRate,
            AVChannelLayoutKey: layoutData,
        ]
        // Ungültige Einstellungen würfen in AVFoundation eine (nicht fangbare)
        // Objective-C-Exception -- vorher prüfen, dann bleibt nur das Original.
        guard writer.canApply(outputSettings: aacSettings, forMediaType: .audio) else {
            throw PodcastImportError.unreadable
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw PodcastImportError.unreadable }
        writer.add(input)

        guard reader.startReading() else { throw reader.error ?? PodcastImportError.unreadable }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? PodcastImportError.unreadable
        }
        writer.startSession(atSourceTime: .zero)

        let pump = SamplePump(reader: reader, output: output, input: input)
        let appendFailed = await pump.run()

        if appendFailed || reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw writer.error ?? reader.error ?? PodcastImportError.unreadable
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PodcastImportError.unreadable }
    }
}

/// Schiebt die gelesenen Samples in den Writer. Eigene Klasse, damit das
/// "nur einmal fortsetzen" ohne veränderte, eingefangene Variablen auskommt.
private final class SamplePump {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "teach.podcast.compress")
    private var continuation: CheckedContinuation<Bool, Never>?

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.reader = reader
        self.output = output
        self.input = input
    }

    /// `true` = Anhängen ist fehlgeschlagen.
    func run() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                self.continuation = continuation
                self.input.requestMediaDataWhenReady(on: self.queue) { self.pumpSamples() }
            }
        }
    }

    /// Läuft immer auf `queue`.
    private func pumpSamples() {
        guard continuation != nil else { return }
        while input.isReadyForMoreMediaData {
            guard let buffer = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                finish(failed: false)
                return
            }
            if !input.append(buffer) {
                reader.cancelReading()
                input.markAsFinished()
                finish(failed: true)
                return
            }
        }
    }

    private func finish(failed: Bool) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: failed)
    }
}
