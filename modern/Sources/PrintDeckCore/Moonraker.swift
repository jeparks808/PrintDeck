import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PrinterError: Error, LocalizedError, Equatable {
    case badAddress(String)
    case http(Int, String)
    case badReply(String)
    case notMoonraker

    public var errorDescription: String? {
        switch self {
        case .badAddress(let a): "“\(a)” isn't a printer address."
        case .http(let code, let msg): msg.isEmpty ? "The printer answered HTTP \(code)." : msg
        case .badReply(let what): "Unexpected reply from the printer (\(what))."
        case .notMoonraker: "No Moonraker answered at that address."
        }
    }
}

/// Which optional Klipper objects this printer has, picked from `printer.objects.list` by name, as PrintDeck's iPad
/// app does for COSMOS: the chamber sensor, the auxiliary and case fans, and the case light.
public struct PrinterObjects: Sendable, Equatable {
    public var chamberSensor: String?   // full object name, e.g. "temperature_sensor chamber"
    public var auxFan: String?          // fan_generic name, e.g. "aux_fan"
    public var caseFan: String?
    public var caseLed: String?         // led / neopixel name, e.g. "case"
    public var ledKind: String = "led"
    public var hasPartFan = false
    public var hasBedMesh = false

    public init() {}

    public init(objectNames: [String]) {
        func names(_ prefix: String) -> [String] {
            objectNames.filter { $0.hasPrefix(prefix + " ") }.map { String($0.dropFirst(prefix.count + 1)) }
        }
        func pick(_ list: [String], _ words: [String], excluding: String? = nil) -> String? {
            for w in words {
                if let hit = list.first(where: { $0.lowercased().contains(w) && $0 != excluding }) { return hit }
            }
            return nil
        }
        let generic = names("fan_generic")
        auxFan = pick(generic, ["aux", "side"])
        caseFan = pick(generic, ["chamber", "box", "case", "exhaust"], excluding: auxFan)
        let sensors = names("temperature_sensor")
        chamberSensor = pick(sensors, ["chamber", "box", "enclosure"]).map { "temperature_sensor " + $0 }
        if let led = pick(names("led"), ["case", "chamber", "light"]) {
            caseLed = led
            ledKind = "led"
        } else if let px = pick(names("neopixel"), ["case", "chamber", "light"]) {
            caseLed = px
            ledKind = "neopixel"
        }
        hasPartFan = objectNames.contains("fan")
        hasBedMesh = objectNames.contains("bed_mesh")
    }

    /// The objects (and fields) the dashboard polls.
    public var queryObjects: [String] {
        var o = ["print_stats", "extruder", "heater_bed", "virtual_sdcard", "display_status", "gcode_move",
                 "toolhead", "webhooks"]
        if hasPartFan { o.append("fan") }
        if let chamberSensor { o.append(chamberSensor) }
        if let auxFan { o.append("fan_generic " + auxFan) }
        if let caseFan { o.append("fan_generic " + caseFan) }
        if let caseLed { o.append("\(ledKind) \(caseLed)") }
        return o
    }
}

/// Talks to a Klipper printer through Moonraker's HTTP API (https://moonraker.readthedocs.io). Used for
/// OpenCentauri COSMOS on the Centauri Carbon, and it works with any Moonraker printer.
public struct MoonrakerClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    /// `address` is what someone types: "192.168.0.185", "printer.local:7125" or "http://host:port".
    /// With no port, port 80 is used (COSMOS serves Moonraker there; a stock Klipper install uses 7125).
    public init(address: String, session: URLSession = .shared) throws {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { throw PrinterError.badAddress(address) }
        if !a.contains("://") { a = "http://" + a }
        while a.hasSuffix("/") { a.removeLast() }
        guard let url = URL(string: a), url.host != nil else { throw PrinterError.badAddress(address) }
        baseURL = url
        self.session = session
    }

    public var host: String { baseURL.host ?? "" }

    // MARK: Requests

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        // Object names contain spaces; Moonraker wants them percent-encoded, and "+" must not appear.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url!
    }

    /// Sends a request and returns the `result` of Moonraker's JSON reply.
    func call(_ method: String, _ path: String, _ query: [URLQueryItem] = [], timeout: TimeInterval = 8) async throws -> Any {
        var req = URLRequest(url: url(path, query), timeoutInterval: timeout)
        req.httpMethod = method
        let (data, response) = try await session.fetch(req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? J.parse(data)
        if code != 200 {
            let msg = J.string(J.dict(J.dict(json), "error"), "message") ?? ""
            throw PrinterError.http(code, msg == "Unknown" ? "" : msg)
        }
        guard let root = J.dict(json), let result = root["result"] else { throw PrinterError.badReply(path) }
        return result
    }

    // MARK: Reading

    /// Moonraker's `server/info`: whether Klippy is connected and its state ("ready", "startup", "shutdown", "error").
    public func serverInfo() async throws -> (klippyState: String, version: String) {
        let r = J.dict(try await call("GET", "/server/info"))
        guard let r else { throw PrinterError.notMoonraker }
        return (J.string(r, "klippy_state") ?? "unknown", J.string(r, "moonraker_version") ?? "")
    }

    public func objects() async throws -> PrinterObjects {
        let r = J.dict(try await call("GET", "/printer/objects/list"))
        let names = (J.array(r, "objects") as? [String]) ?? []
        return PrinterObjects(objectNames: names)
    }

    public func snapshot(_ objects: PrinterObjects) async throws -> PrinterSnapshot {
        let q = objects.queryObjects.map { URLQueryItem(name: $0, value: nil) }
        let r = J.dict(try await call("GET", "/printer/objects/query", q, timeout: 5))
        return Self.snapshot(status: J.dict(r, "status") ?? [:], objects: objects)
    }

    /// Builds a snapshot from a `printer.objects.query` status object.
    public static func snapshot(status s: [String: Any], objects: PrinterObjects) -> PrinterSnapshot {
        var p = PrinterSnapshot()
        let stats = J.dict(s, "print_stats")
        let webhooks = J.dict(s, "webhooks")
        if let ws = J.string(webhooks, "state"), ws != "ready" {
            p.state = .notReady
            p.message = J.string(webhooks, "state_message") ?? ws
        } else {
            p.state = JobState(rawValue: J.string(stats, "state") ?? "") ?? .unknown
            p.message = J.string(stats, "message") ?? ""
        }
        p.filename = J.string(stats, "filename") ?? ""
        p.printDuration = J.double(stats, "print_duration") ?? 0
        p.totalDuration = J.double(stats, "total_duration") ?? 0
        p.filamentUsed = J.double(stats, "filament_used") ?? 0
        let info = J.dict(stats, "info")
        p.currentLayer = J.int(info, "current_layer")
        p.totalLayer = J.int(info, "total_layer")

        // Slicer-reported progress (M73) when there is one, else how far through the file the printer has read.
        let display = J.double(J.dict(s, "display_status"), "progress") ?? 0
        let file = J.double(J.dict(s, "virtual_sdcard"), "progress") ?? 0
        p.progress = p.state == .complete ? 1 : min(1, max(0, display > 0 ? display : file))

        func heater(_ name: String) -> Heater? {
            guard let h = J.dict(s, name), let t = J.double(h, "temperature") else { return nil }
            return Heater(temperature: t, target: J.double(h, "target") ?? 0)
        }
        p.nozzle = heater("extruder")
        p.bed = heater("heater_bed")
        if let c = objects.chamberSensor { p.chamber = J.double(J.dict(s, c), "temperature") }

        if objects.hasPartFan { p.partFan = J.double(J.dict(s, "fan"), "speed") }
        if let f = objects.auxFan { p.auxFan = J.double(J.dict(s, "fan_generic " + f), "speed") }
        if let f = objects.caseFan { p.caseFan = J.double(J.dict(s, "fan_generic " + f), "speed") }
        if let led = objects.caseLed,
           let colors = J.array(J.dict(s, "\(objects.ledKind) \(led)"), "color_data") as? [[Any]] {
            p.lightOn = colors.contains { $0.contains { (J.double($0) ?? 0) > 0 } }
        }

        let move = J.dict(s, "gcode_move")
        p.speedFactor = J.double(move, "speed_factor") ?? 1
        let tool = J.dict(s, "toolhead")
        p.homedAxes = J.string(tool, "homed_axes") ?? ""
        p.position = (J.array(tool, "position") ?? []).compactMap { J.double($0) }
        return p
    }

    /// G-code files on the printer, newest first.
    public func files() async throws -> [PrintFile] {
        let r = try await call("GET", "/server/files/list", [URLQueryItem(name: "root", value: "gcodes")])
        return Self.files(from: r)
    }

    public static func files(from result: Any) -> [PrintFile] {
        let list = (result as? [Any]) ?? []
        return list.compactMap { item -> PrintFile? in
            let d = J.dict(item)
            guard let path = J.string(d, "path"), path.lowercased().hasSuffix(".gcode") else { return nil }
            return PrintFile(path: path,
                             modified: Date(timeIntervalSince1970: J.double(d, "modified") ?? 0),
                             size: Int64(J.double(d, "size") ?? 0))
        }.sorted { $0.modified > $1.modified }
    }

    /// The slicer details of a file. Moonraker only reads files it has been told about, so when it doesn't know this
    /// one yet (HTTP 404) it is asked to scan it now (`metascan`), which can take a few seconds for a big file.
    public func metadata(for path: String) async throws -> FileMetadata {
        let q = [URLQueryItem(name: "filename", value: path)]
        do {
            return Self.metadata(from: J.dict(try await call("GET", "/server/files/metadata", q)) ?? [:])
        } catch PrinterError.http(404, _) {
            return Self.metadata(from: J.dict(try await call("POST", "/server/files/metascan", q, timeout: 60)) ?? [:])
        }
    }

    public static func metadata(from r: [String: Any]) -> FileMetadata {
        var m = FileMetadata()
        m.estimatedTime = J.double(r, "estimated_time")
        m.filamentWeight = J.double(r, "filament_weight_total")
        m.layerCount = J.int(r, "layer_count")
        m.objectHeight = J.double(r, "object_height")
        m.slicer = J.string(r, "slicer")
        m.nozzleDiameter = J.double(r, "nozzle_diameter")
        m.layerHeight = J.double(r, "layer_height")
        m.firstLayerNozzle = J.double(r, "first_layer_extr_temp")
        m.firstLayerBed = J.double(r, "first_layer_bed_temp")
        // Colours come as a list; types and names as lists or as a JSON string of a list (ElegooSlicer).
        func list(_ k: String) -> [String] {
            if let a = J.array(r, k) as? [String] { return a }
            if let s = J.string(r, k) {
                if let d = s.data(using: .utf8), let a = (try? J.parse(d)) as? [String] { return a }
                return s.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return []
        }
        let colors = list("filament_colors"), types = list("filament_type"), names = list("filament_name")
        let n = max(colors.count, types.count, names.count)
        m.filaments = (0..<n).map { i in
            Filament(color: i < colors.count ? colors[i] : nil, type: i < types.count ? types[i] : nil,
                     name: i < names.count ? names[i] : nil)
        }
        let thumbs = (J.array(r, "thumbnails") ?? []).compactMap { J.dict($0) }
            .sorted { (J.double($0, "width") ?? 0) < (J.double($1, "width") ?? 0) }
        m.thumbnails = thumbs.compactMap { J.string($0, "relative_path") }
        return m
    }

    /// A file under the gcodes root, for downloading it or one of its thumbnails.
    public func fileURL(_ relativePath: String) -> URL {
        var u = baseURL.appendingPathComponent("server/files/gcodes")
        for part in relativePath.split(separator: "/") { u.appendPathComponent(String(part)) }
        return u
    }

    /// The first webcam Moonraker knows about, as (stream URL, snapshot URL). Relative URLs are resolved against the
    /// printer's address.
    public func webcam() async throws -> (stream: URL?, snapshot: URL?) {
        let r = J.dict(try await call("GET", "/server/webcams/list"))
        let cams = (J.array(r, "webcams") ?? []).compactMap { J.dict($0) }
        guard let cam = cams.first(where: { ($0["enabled"] as? Bool) ?? true }) ?? cams.first else { return (nil, nil) }
        func resolve(_ s: String?) -> URL? {
            guard let s, !s.isEmpty else { return nil }
            return URL(string: s, relativeTo: baseURL)?.absoluteURL
        }
        return (resolve(J.string(cam, "stream_url")), resolve(J.string(cam, "snapshot_url")))
    }

    // MARK: Commands

    public func pause() async throws { _ = try await call("POST", "/printer/print/pause") }
    public func resume() async throws { _ = try await call("POST", "/printer/print/resume") }
    public func cancel() async throws { _ = try await call("POST", "/printer/print/cancel") }

    public func startPrint(_ path: String) async throws {
        _ = try await call("POST", "/printer/print/start", [URLQueryItem(name: "filename", value: path)])
    }

    /// Runs G-code. Moonraker answers once Klipper has run it, so long moves can take a while.
    public func gcode(_ script: String, timeout: TimeInterval = 30) async throws {
        _ = try await call("POST", "/printer/gcode/script", [URLQueryItem(name: "script", value: script)], timeout: timeout)
    }

    public func setNozzleTarget(_ c: Int) async throws { try await gcode("SET_HEATER_TEMPERATURE HEATER=extruder TARGET=\(c)") }
    public func setBedTarget(_ c: Int) async throws { try await gcode("SET_HEATER_TEMPERATURE HEATER=heater_bed TARGET=\(c)") }
    public func setSpeedPercent(_ pct: Int) async throws { try await gcode("M220 S\(pct)") }
    public func setPartFan(_ fraction: Double) async throws {
        try await gcode("M106 S\(Int((max(0, min(1, fraction)) * 255).rounded()))")
    }
    public func setGenericFan(_ name: String, _ fraction: Double) async throws {
        try await gcode(String(format: "SET_FAN_SPEED FAN=%@ SPEED=%.2f", name, max(0, min(1, fraction))))
    }
    public func setLight(_ objects: PrinterObjects, on: Bool) async throws {
        guard let led = objects.caseLed else { return }
        try await gcode("SET_LED LED=\(led) WHITE=\(on ? 1 : 0)")
    }
}

extension URLSession {
    /// `data(for:)` that also works with swift-corelibs-foundation on Linux.
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            let task = dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error) }
                else if let response { cont.resume(returning: (data ?? Data(), response)) }
                else { cont.resume(throwing: PrinterError.badReply("no response")) }
            }
            task.resume()
        }
    }
}
