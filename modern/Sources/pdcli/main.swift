import Foundation
import PrintDeckCore

// pdcli: a command-line check of PrintDeckCore against a real printer, for Linux or macOS. Read-only.
//   swift run pdcli 192.168.0.185          status once
//   swift run pdcli 192.168.0.185 watch    status every 2 s
//   swift run pdcli 192.168.0.185 files    newest files

let args = CommandLine.arguments.dropFirst()
guard let address = args.first else {
    print("usage: pdcli <printer-address> [status|watch|files|camera]")
    exit(2)
}
let mode = args.dropFirst().first ?? "status"

func describe(_ s: PrinterSnapshot) -> String {
    var parts = [s.state.label]
    if !s.message.isEmpty { parts.append("(\(s.message))") }
    if let n = s.nozzle { parts.append(String(format: "nozzle %.1f/%.0f", n.temperature, n.target)) }
    if let b = s.bed { parts.append(String(format: "bed %.1f/%.0f", b.temperature, b.target)) }
    if let c = s.chamber { parts.append(String(format: "chamber %.1f", c)) }
    if s.state.isActive {
        parts.append("\(s.filename) \(Int(s.progress * 100))%")
        if let l = s.currentLayer, let t = s.totalLayer { parts.append("layer \(l)/\(t)") }
        parts.append("elapsed " + formatDuration(s.printDuration))
    }
    let fans = [("part", s.partFan), ("aux", s.auxFan), ("case", s.caseFan)].compactMap { name, v in
        v.map { "\(name) \(Int($0 * 100))%" }
    }
    if !fans.isEmpty { parts.append("fans " + fans.joined(separator: " ")) }
    if let l = s.lightOn { parts.append("light " + (l ? "on" : "off")) }
    parts.append("speed \(Int(s.speedFactor * 100))%")
    return parts.joined(separator: "  ")
}

do {
    let client = try MoonrakerClient(address: address)
    let info = try await client.serverInfo()
    print("Moonraker \(info.version) at \(client.baseURL), Klippy \(info.klippyState)")
    let objects = try await client.objects()
    print("objects: chamber=\(objects.chamberSensor ?? "-") aux=\(objects.auxFan ?? "-") case=\(objects.caseFan ?? "-") light=\(objects.caseLed ?? "-") mesh=\(objects.hasBedMesh)")
    switch mode {
    case "files":
        for f in try await client.files().prefix(10) {
            print(String(format: "%@  %7.1f KB  %@", f.modified.description, Double(f.size) / 1024, f.displayName))
        }
    case "camera":
        let cam = try await client.webcam()
        print("stream \(cam.stream?.absoluteString ?? "-")  snapshot \(cam.snapshot?.absoluteString ?? "-")")
    case "watch":
        while true {
            print(describe(try await client.snapshot(objects)))
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    default:
        print(describe(try await client.snapshot(objects)))
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
