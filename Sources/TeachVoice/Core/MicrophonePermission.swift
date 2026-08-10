import AVFoundation
import UIKit

/// Zentrale Stelle für den Mikrofon-Berechtigungsstatus. Wichtig für das
/// Nutzererlebnis: iOS zeigt den echten System-Dialog nur EIN einziges Mal
/// überhaupt an. Wurde der Zugriff schon einmal abgelehnt, öffnet ein
/// erneuter Aufruf von `requestRecordPermission` keinen Dialog mehr – dann
/// bleibt nur der Umweg über die App-Einstellungen.
enum MicrophonePermission {
    static var isGranted: Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// Fordert den Zugriff an (zeigt den System-Dialog, falls noch nie gefragt),
    /// oder öffnet direkt die App-Einstellungen, falls schon einmal abgelehnt.
    static func requestOrOpenSettings() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        case .denied:
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
        case .granted:
            break
        @unknown default:
            break
        }
    }
}
