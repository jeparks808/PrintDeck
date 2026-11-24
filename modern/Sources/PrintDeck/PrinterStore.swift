#if os(iOS)
import Foundation
import Observation
import PrintDeckCore

/// One temperature reading for the graphs.
struct TempSample: Identifiable, Sendable {
    let time: Date
    let nozzle: Double?
    let bed: Double?
    let chamber: Double?
    var id: Date { time }
}

/// The app's connection to one printer: polls it, keeps a short temperature history, and runs commands.
@MainActor @Observable
final class PrinterStore {
    static let addressKey = "PDPrinterAddress"

    var address: String = UserDefaults.standard.string(forKey: PrinterStore.addressKey) ?? ""
    private(set) var client: MoonrakerClient?
    private(set) var objects = PrinterObjects()
    private(set) var snapshot: PrinterSnapshot?
    private(set) var connected = false
    private(set) var lastError: String?
    private(set) var lastUpdate: Date?
    private(set) var history: [TempSample] = []
    private(set) var files: [PrintFile] = []
    private(set) var filesLoading = false
    private(set) var cameraStream: URL?
    private(set) var cameraSnapshot: URL?
    /// Slicer details of files we've asked about (the running job's, and files opened in the list).
    private(set) var metadata: [String: FileMetadata] = [:]
    /// The last command's failure, shown as an alert.
    var actionError: String?
    private(set) var actionRunning = false

    /// How long the graphs reach back.
    let historySpan: TimeInterval = 10 * 60
    private var pollTask: Task<Void, Never>?
    private var metadataRequested: Set<String> = []

    var hasPrinter: Bool { !address.isEmpty }
    var state: JobState { connected ? (snapshot?.state ?? .unknown) : .unknown }

    // MARK: Connection

    /// Checks the address answers as Moonraker, then remembers it and starts polling.
    func connect(to newAddress: String) async throws {
        let c = try MoonrakerClient(address: newAddress)
        _ = try await c.serverInfo()
        address = newAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(address, forKey: Self.addressKey)
        stop()
        client = nil
        snapshot = nil
        history = []
        files = []
        metadata = [:]
        metadataRequested = []
        start()
    }

    func forget() {
        stop()
        address = ""
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        client = nil
        snapshot = nil
        connected = false
    }

    func start() {
        guard hasPrinter, pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                try? await Task.sleep(nanoseconds: self.connected ? 1_500_000_000 : 4_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        do {
            if client == nil || !connected {
                let c = try MoonrakerClient(address: address)
                _ = try await c.serverInfo()
                let o = try await c.objects()
                let cam = try? await c.webcam()
                client = c
                objects = o
                cameraStream = cam?.stream
                cameraSnapshot = cam?.snapshot
                Task { await self.refreshFiles() }
            }
            guard let client else { return }
            let s = try await client.snapshot(objects)
            snapshot = s
            connected = true
            lastError = nil
            lastUpdate = Date()
            record(s)
            if !s.filename.isEmpty { loadMetadata(s.filename) }
        } catch {
            // Klippy restarting makes the object query fail while Moonraker still answers: keep trying quietly.
            if connected { connected = false }
            lastError = error.localizedDescription
        }
    }

    private func record(_ s: PrinterSnapshot) {
        let now = Date()
        if let last = history.last, now.timeIntervalSince(last.time) < 1 { return }
        history.append(TempSample(time: now, nozzle: s.nozzle?.temperature, bed: s.bed?.temperature, chamber: s.chamber))
        let cutoff = now.addingTimeInterval(-historySpan)
        if let first = history.firstIndex(where: { $0.time >= cutoff }), first > 0 { history.removeFirst(first) }
    }

    // MARK: Files

    func refreshFiles() async {
        guard let client else { return }
        filesLoading = true
        defer { filesLoading = false }
        if let f = try? await client.files() { files = f }
    }

    func loadMetadata(_ path: String) {
        guard let client, !metadataRequested.contains(path) else { return }
        metadataRequested.insert(path)
        Task {
            if let m = try? await client.metadata(for: path) { metadata[path] = m }
            else { metadataRequested.remove(path) }   // not scanned yet: ask again later
        }
    }

    func thumbnailURL(for path: String) -> URL? {
        guard let client, let rel = metadata[path]?.thumbnails.last else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return client.fileURL(folder.isEmpty ? rel : folder + "/" + rel)
    }

    /// Seconds left for the running job, or nil when there's nothing to estimate.
    var remaining: Double? {
        guard let s = snapshot, s.state.isActive else { return nil }
        return estimatedRemaining(elapsed: s.printDuration, progress: s.progress,
                                  slicerTotal: metadata[s.filename]?.estimatedTime)
    }

    // MARK: Commands

    /// Runs a printer command, showing its error (if any) as an alert, then polls at once so the screen catches up.
    func run(_ what: @escaping @Sendable (MoonrakerClient) async throws -> Void) {
        guard let client else { return }
        actionRunning = true
        Task {
            do { try await what(client) } catch { actionError = error.localizedDescription }
            actionRunning = false
            await poll()
        }
    }

    func pause() { run { try await $0.pause() } }
    func resume() { run { try await $0.resume() } }
    func cancel() { run { try await $0.cancel() } }
    func startPrint(_ path: String) { run { try await $0.startPrint(path) } }
    func setNozzle(_ c: Int) { run { try await $0.setNozzleTarget(c) } }
    func setBed(_ c: Int) { run { try await $0.setBedTarget(c) } }
    func setSpeed(_ pct: Int) { run { try await $0.setSpeedPercent(pct) } }
    func setPartFan(_ v: Double) { run { try await $0.setPartFan(v) } }
    func setFan(_ name: String, _ v: Double) { run { try await $0.setGenericFan(name, v) } }
    func setLight(_ on: Bool) {
        let o = objects
        run { try await $0.setLight(o, on: on) }
    }
}
#endif
