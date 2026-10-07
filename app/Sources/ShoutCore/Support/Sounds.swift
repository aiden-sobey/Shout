import AppKit

/// Short system sounds for start / stop / cancel / error.
@MainActor
final class Sounds {
    private let start = NSSound(named: "Tink")
    private let stop = NSSound(named: "Pop")
    private let cancel = NSSound(named: "Bottle")
    private let error = NSSound(named: "Basso")

    init() {
        for sound in [start, stop, cancel, error] { sound?.volume = 0.35 }
    }

    func play(_ cue: DictationController.Cue) {
        let sound: NSSound? = switch cue {
        case .start: start
        case .stop: stop
        case .cancel: cancel
        case .error: error
        }
        sound?.stop()
        sound?.play()
    }
}
