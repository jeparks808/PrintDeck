import Foundation
import Testing
@testable import PrintDeckCore

/// Replies saved from a real Centauri Carbon running OpenCentauri COSMOS (Moonraker).
func fixture(_ name: String) throws -> Any {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
    return J.dict(try J.parse(Data(contentsOf: url)))!["result"]!
}

@Test func picksCentauriObjects() throws {
    let names = (J.dict(try fixture("objects-list"))!["objects"] as! [String])
    let o = PrinterObjects(objectNames: names)
    #expect(o.chamberSensor == "temperature_sensor chamber")
    #expect(o.auxFan == "aux_fan")
    #expect(o.caseFan == "case_fan")
    #expect(o.caseLed == "case")
    #expect(o.hasPartFan)
    #expect(o.hasBedMesh)
    #expect(o.queryObjects.contains("fan_generic case_fan"))
}

@Test func parsesIdleSnapshot() throws {
    let names = (J.dict(try fixture("objects-list"))!["objects"] as! [String])
    let status = J.dict(J.dict(try fixture("query-idle"))!, "status")!
    let s = MoonrakerClient.snapshot(status: status, objects: PrinterObjects(objectNames: names))
    #expect(s.state == .standby)
    #expect(s.state.label == "Ready")
    #expect(s.nozzle != nil && s.bed != nil && s.chamber != nil)
    #expect(s.partFan == 0)
    #expect(s.auxFan == 0)
    #expect(s.lightOn == true)       // color_data [[0, 0, 0, 1]]: white on
    #expect(s.speedFactor == 1)
}

@Test func notReadyKlippyWins() {
    let status: [String: Any] = [
        "webhooks": ["state": "shutdown", "state_message": "MCU 'mcu' shutdown"],
        "print_stats": ["state": "printing"],
    ]
    let s = MoonrakerClient.snapshot(status: status, objects: PrinterObjects())
    #expect(s.state == .notReady)
    #expect(s.message == "MCU 'mcu' shutdown")
}

@Test func printingProgressAndLayers() {
    let status: [String: Any] = [
        "webhooks": ["state": "ready"],
        "print_stats": ["state": "printing", "filename": "a/b.gcode", "print_duration": 600.0,
                        "info": ["current_layer": 12, "total_layer": 100]],
        "display_status": ["progress": 0.0],
        "virtual_sdcard": ["progress": 0.25],
    ]
    let s = MoonrakerClient.snapshot(status: status, objects: PrinterObjects())
    #expect(s.state.isActive)
    #expect(s.progress == 0.25)        // no M73 progress, so the file position is used
    #expect(s.currentLayer == 12 && s.totalLayer == 100)
}

@Test func filesNewestFirstGcodeOnly() throws {
    let files = MoonrakerClient.files(from: try fixture("files-list"))
    #expect(!files.isEmpty)
    #expect(files.allSatisfy { $0.path.lowercased().hasSuffix(".gcode") })
    #expect(zip(files, files.dropFirst()).allSatisfy { $0.modified >= $1.modified })
    #expect(PrintFile(path: "x/Cube.gcode", modified: .now, size: 1).displayName == "Cube")
}

@Test func addresses() throws {
    #expect(try MoonrakerClient(address: "192.168.0.185").baseURL.absoluteString == "http://192.168.0.185")
    #expect(try MoonrakerClient(address: " printer.local:7125/ ").baseURL.absoluteString == "http://printer.local:7125")
    #expect(throws: PrinterError.self) { try MoonrakerClient(address: "  ") }
    let c = try MoonrakerClient(address: "10.0.0.2")
    #expect(c.fileURL("sub/My File.gcode").absoluteString == "http://10.0.0.2/server/files/gcodes/sub/My%20File.gcode")
    let q = c.url("/printer/objects/query", [URLQueryItem(name: "fan_generic aux_fan", value: nil)])
    #expect(q.absoluteString == "http://10.0.0.2/printer/objects/query?fan_generic%20aux_fan")
}

@Test func remainingTime() {
    #expect(estimatedRemaining(elapsed: 10, progress: 0.01, slicerTotal: 1000) == 990)
    #expect(estimatedRemaining(elapsed: 10, progress: 0.01, slicerTotal: nil) == nil)
    // Past 25 % the extrapolation alone counts: 1000 s for half → 1000 s left.
    #expect(estimatedRemaining(elapsed: 1000, progress: 0.5, slicerTotal: 5000) == 1000)
    #expect(formatDuration(3725) == "1h 02m")
    #expect(formatDuration(65) == "1m 05s")
}

@Test func mjpegSplitsFramesAcrossChunks() {
    let frame1: [UInt8] = [0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]
    let frame2: [UInt8] = [0xFF, 0xD8, 9, 0xFF, 0xD9]
    let stream = Array("--boundary\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + frame1
        + Array("\r\n--boundary\r\n\r\n".utf8) + frame2
    var s = MJPEGSplitter()
    var frames: [Data] = []
    // Feed it in awkward 3-byte chunks so markers get split.
    var i = 0
    while i < stream.count {
        frames += s.append(Data(stream[i..<min(i + 3, stream.count)]))
        i += 3
    }
    #expect(frames == [Data(frame1), Data(frame2)])
}

@Test func elegooMetadata() throws {
    let m = MoonrakerClient.metadata(from: J.dict(try fixture("metadata-elegoo"))!)
    #expect(m.estimatedTime == 8306)
    #expect(m.layerCount == 291)
    #expect(m.layerHeight == 0.24 && m.nozzleDiameter == 0.6)
    #expect(m.firstLayerNozzle == 220 && m.firstLayerBed == 60)
    #expect(m.filaments.count == 4)
    #expect(m.filaments[1] == Filament(color: "#FFFF00", type: "PLA", name: "SUNLU PLA @System - Yellow"))
    #expect(m.thumbnails.last == ".thumbs/part-144x144.png")   // largest last
}
