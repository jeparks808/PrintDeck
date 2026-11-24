import Foundation

/// What the printer is doing, from Klipper's `print_stats.state` (and Moonraker's view of Klippy).
public enum JobState: String, Sendable, Equatable {
    case standby, printing, paused, complete, cancelled, error
    /// Klippy itself isn't ready (starting, shut down or in an error state).
    case notReady
    case unknown

    public var isActive: Bool { self == .printing || self == .paused }

    public var label: String {
        switch self {
        case .standby: "Ready"
        case .printing: "Printing"
        case .paused: "Paused"
        case .complete: "Finished"
        case .cancelled: "Cancelled"
        case .error: "Error"
        case .notReady: "Not ready"
        case .unknown: "Unknown"
        }
    }
}

public struct Heater: Sendable, Equatable {
    public var temperature: Double
    public var target: Double
    public init(temperature: Double, target: Double) {
        self.temperature = temperature
        self.target = target
    }
}

/// One reading of everything the dashboard shows. Built from a Moonraker `printer.objects.query` result.
public struct PrinterSnapshot: Sendable, Equatable {
    public var state: JobState = .unknown
    /// Klipper's own message: why it's not ready, or the print_stats message.
    public var message: String = ""
    public var filename: String = ""
    /// 0...1
    public var progress: Double = 0
    /// Seconds spent printing (excludes pauses).
    public var printDuration: Double = 0
    /// Seconds since the job started, pauses included.
    public var totalDuration: Double = 0
    public var currentLayer: Int?
    public var totalLayer: Int?
    /// Millimetres of filament used so far.
    public var filamentUsed: Double = 0

    public var nozzle: Heater?
    public var bed: Heater?
    public var chamber: Double?

    /// Fan speeds, 0...1. `nil` when the printer has no such fan.
    public var partFan: Double?
    public var auxFan: Double?
    public var caseFan: Double?

    /// 1.0 = 100 %.
    public var speedFactor: Double = 1
    /// `nil` when the printer has no case light.
    public var lightOn: Bool?

    public var homedAxes: String = ""
    public var position: [Double] = []

    public init() {}
}

/// A G-code file stored on the printer.
public struct PrintFile: Sendable, Equatable, Identifiable, Hashable {
    public var path: String
    public var modified: Date
    public var size: Int64
    public var id: String { path }

    /// The file name without folders or the `.gcode` extension.
    public var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".gcode") ? String(name.dropLast(6)) : name
    }

    public init(path: String, modified: Date, size: Int64) {
        self.path = path
        self.modified = modified
        self.size = size
    }
}

/// What the slicer wrote into a file's header, as Moonraker reports it. Every field is optional:
/// Moonraker only knows it once it has scanned the file.
public struct FileMetadata: Sendable, Equatable {
    public var estimatedTime: Double?
    public var filamentWeight: Double?
    public var layerCount: Int?
    public var objectHeight: Double?
    public var slicer: String?
    /// Thumbnail paths relative to the gcodes root, largest last.
    public var thumbnails: [String] = []
    public init() {}
}

/// Time left, blending the slicer's estimate with an extrapolation from progress. Slicer estimates can be far off
/// (a 2 h 18 min slice once took 3 h 41 min), so the extrapolation takes over as the print goes on.
public func estimatedRemaining(elapsed: Double, progress: Double, slicerTotal: Double?) -> Double? {
    let slicer = slicerTotal.map { max(0, $0 - elapsed) }
    guard progress >= 0.02, elapsed >= 60 else { return slicer }
    let extrapolated = elapsed * (1 - progress) / progress
    guard let slicer else { return extrapolated }
    let w = min(1, progress / 0.25)
    return (1 - w) * slicer + w * extrapolated
}

/// "2h 05m", "12m 30s", "45s".
public func formatDuration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    if m > 0 { return String(format: "%dm %02ds", m, sec) }
    return "\(sec)s"
}
